//SPDX-License-Identifier: MIT

/** 
@title Xpandr4626
@author Nikar0 
@notice Minimal Vault based on EIP 4626

www.github.com/nikar0/Xpandr4626 - www.twitter.com/Nikar0_
**/

pragma solidity 0.8.17;

import {ReentrancyGuard} from "./interfaces/solmate//ReentrancyGuard.sol";
import {ERC4626} from "./interfaces/solmate/ERC4626.sol";
import {ERC20} from "./interfaces/solmate/ERC20.sol";
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";


/**
Implementation of a vault to deposit funds for yield optimizing
This is the contract that receives funds & users interface with
The strategy itself is implemented in a separate Strategy contract
 */
contract Xpandr4626Vault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                           VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    struct StratCandidate {
        address implementation;
        uint256 proposedTime;
    }

    StratCandidate public stratCandidate;         //The last proposed strategy to switch to.
    IStrategy public strategy;                    //The strategy currently in use by the vault.
    uint256 constant approvalDelay = 43200;       //Delay before a strat can be approved. 12 hours
    uint256 vaultProfit;                          //Sum of the yield earned by strategies attached to the vault. In 'asset' amount.
    mapping(address => uint64) lastUserDeposit;   //Deposit timer to prevent spam w/ 0 withdraw fee
  
    event NewStratQueued(address implementation);
    event SwapStrat(address implementation);
    event StuckTokens(address caller, uint256 amount, address token);

    /**
     Initializes the vault and it's own receipt token
     This token is minted when someone deposits. It's burned in order
     to withdraw the corresponding portion of the underlying assets.
     */
    constructor (ERC20 _asset, IStrategy _strategy)
       ERC4626(
            _asset,
            string(abi.encodePacked("Tester")),
            string(abi.encodePacked("LP"))
        )
    {
        strategy = _strategy;
        totalSupply = type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/
    function depositAll() external {
        deposit(asset.balanceOf(msg.sender), msg.sender);
    }

    //Entrypoint of funds into the system. The vault then deposits funds into the strategy.  
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if(lastUserDeposit[msg.sender] != 0) {if(lastUserDeposit[msg.sender] < uint64(block.timestamp + 600)) {revert XpandrErrors.UnderTimeLock();}}
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}

        shares = previewDeposit(assets);
        if(shares == 0){revert XpandrErrors.ZeroAmount();}

        vaultProfit = vaultProfit + strategy.harvestProfit();
        lastUserDeposit[msg.sender] = uint64(block.timestamp);

        asset.safeTransferFrom(msg.sender, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        
        _mint(msg.sender, shares);
        _earn();
        emit Deposit(msg.sender, receiver, assets, shares);

        if(strategy.harvestOnDeposit() == 1) {strategy.afterDeposit();}
    }

    //Function to send funds into the strategy and put them to work.
    //It's primarily called by the vault's deposit() function.
    function _earn() internal {
        uint _bal = idleFunds();
        asset.safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    function withdrawAll() external {
        withdraw(asset.balanceOf(msg.sender), msg.sender, msg.sender);
    }

    /**
     Exit the system. The vault will withdraw the required tokens
     from the strategy and semd to the token holder. A proportional number of receipt
     tokens are burned in the process.
     */

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256 shares) {
       if(msg.sender != receiver && msg.sender != owner){revert XpandrErrors.NotAccountOwner();}
        shares = previewWithdraw(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
        if(shares > ERC20(address(this)).balanceOf(msg.sender)){revert XpandrErrors.OverBalance();}
       
        _burn(owner, shares);
        strategy.withdraw(assets);

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    //Returns idle funds in the vault
    function idleFunds() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    //Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    //Calculates total amount of 'asset' held by the system. Vault, strategy and contracts it deposits in.
    
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this)) + IStrategy(strategy).balanceOf();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS 
    //////////////////////////////////////////////////////////////*/
    
    //Sets the candidate for the new strat to use with this vault.
    function queueStrat(address _implementation) public onlyAdmin {
        if(address(this) != IStrategy(_implementation).vault()){revert XpandrErrors.InvalidProposal();}
        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: uint64(block.timestamp)
         });

        emit NewStratQueued(_implementation);
    }

    /** 
    Switches the active strat for the strat candidate. After upgrading, the 
    candidate implementation is set to the 0x00 address, and proposedTime to a time 
    happening in +100 years for safety. 
    */
    function swapStrat() public onlyAdmin {
        if(stratCandidate.implementation == address(0)){revert XpandrErrors.ZeroAddress();}
        if(stratCandidate.proposedTime + approvalDelay > uint64(block.timestamp)){revert XpandrErrors.UnderTimeLock();}

        emit SwapStrat(stratCandidate.implementation);
        strategy.retireStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        _earn();
    }

    //Rescues random funds stuck that the strat can't handle.
    function stuckTokens(address _token) external onlyAdmin {
        if(ERC20(_token) == asset){revert XpandrErrors.InvalidTokenOrPath();}

        uint256 amount = ERC20(_token).balanceOf(address(this));
        ERC20(_token).safeTransfer(msg.sender, amount);

        emit StuckTokens(msg.sender, amount, _token);
    }

    /*//////////////////////////////////////////////////////////////
                               UNUSED
    //////////////////////////////////////////////////////////////*/
    
    /**Following functions are included as per EIP-4626 standard but are not meant
    To be used in the context of this vault. As such, they were made void by design.
    This vault does not allow 3rd parties to deposit or withdraw for another Owner.
    */
    function redeem(uint256 shares, address receiver, address owner) public pure override returns (uint256) {if(!false){revert XpandrErrors.UnusedFunction();}}
    function mint(uint256 shares, address receiver) public pure override returns (uint256) {if(!false){revert XpandrErrors.UnusedFunction();}}
    function previewMint(uint256 shares) public pure override returns (uint256){if(!false){revert XpandrErrors.UnusedFunction();}}
    function maxRedeem(address owner) public pure override returns (uint256) {if(!false){revert XpandrErrors.UnusedFunction();}}
}