// SPDX-License-Identifier: No License (None)
// No permissions granted before Sunday, 5th May 2024, then GPL-3.0 after this date.

/** 
@title  - Xpandr4626
@author - Nikar0 
@notice - Mininal, security & gas considerate Vault contract. Used as 2 piece alongside a Strategy contract.
        - Includes: 0% withdraw fee default / Total Vault profit in USD / Deposit buffer.

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


Vault based on EIP-4626 by @joey_santoro, @transmissions11, et all.
https://eips.ethereum.org/EIPS/eip-4626

Using solmate's gas optimized libs
https://github.com/transmissions11/solmate

Special thanks to 543 from Equalizer/Guru_Network for the brainstorming & QA

@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.
**/

pragma solidity ^0.8.19;

import {ReentrancyGuard} from "./interfaces/solmate//ReentrancyGuard.sol";
import {ERC20, ERC4626} from "./interfaces/solmate/ERC4626.sol";
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
Implementation of a vault to deposit funds for yield optimizing
This is the contract that receives funds & users interface with
The strategy itself is implemented in a separate Strategy contract
 */
contract Xpandr4626 is ERC4626, AccessControl, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                           VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }

    StratCandidate public stratCandidate;         //The last proposed strategy to switch to.
    IStrategy public strategy;                    //The strategy currently in use by the vault.
    uint128 constant approvalDelay = 43200;       //Delay before a strat can be approved. 12 hours
    uint128 internal delay;
    uint vaultProfit;                             //Sum of the yield earned by strategies attached to the vault. In USD.
    mapping(address => uint64) lastUserDeposit;   //Deposit timer to prevent spam w/ 0 withdraw fee
  
    event NewStratQueued(address implementation);
    event SwapStrat(address implementation);
    event StuckTokens(address caller, uint amount, address token);

    /**
     Initializes the vault and it's own receipt token
     This token is minted when someone deposits. It's burned in order
     to withdraw the corresponding portion of the underlying assets.
     */
    constructor (ERC20 _asset, IStrategy _strategy)
       ERC4626(
            _asset,
            string(abi.encodePacked("Tester Vault")),
            string(abi.encodePacked("LP"))
        )
    {
        strategy = _strategy;
        totalSupply = type(uint).max;
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function depositAll() external {
        deposit(asset.balanceOf(msg.sender), msg.sender);
    }

    //Entrypoint of funds into the system. The vault then deposits funds into the strategy.  
    function deposit(uint assets, address receiver) public override nonReentrant returns (uint shares) {
        if(lastUserDeposit[msg.sender] != 0) {if(lastUserDeposit[msg.sender] < uint64(block.timestamp) + delay) {revert XpandrErrors.UnderTimeLock();}}
        if(msg.sender != receiver){revert XpandrErrors.NotAccountOwner();}

        shares = previewDeposit(assets);
        if(shares == 0 || assets ==0){revert XpandrErrors.ZeroAmount();}

        lastUserDeposit[msg.sender] = uint64(block.timestamp);
        vaultProfit = vaultProfit + strategy.harvestProfit();

        asset.safeTransferFrom(msg.sender, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        
        _mint(msg.sender, shares);
        _earn();
        emit Deposit(msg.sender, receiver, assets, shares);

        if(strategy.harvestOnDeposit() == 1) {strategy.afterDeposit();}
    }

    //Function to send funds into the strategy then deposits in the farm.
    //It's primarily called by the vault's deposit() function.
    function _earn() internal {
        uint bal = asset.balanceOf(address(this));
        asset.safeTransfer(address(strategy), bal);
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

    function withdraw(uint assets, address receiver, address _owner) public override nonReentrant returns (uint shares) {
       if(msg.sender != receiver && msg.sender != _owner){revert XpandrErrors.NotAccountOwner();}
        shares = previewWithdraw(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
        if(shares > ERC20(address(this)).balanceOf(msg.sender)){revert XpandrErrors.OverCap();}
       
        _burn(_owner, shares);
        strategy.withdraw(assets);

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    //Returns idle funds in the vault
    function idleFunds() public view returns (uint) {
        return asset.balanceOf(address(this));
    }

    //Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() public view returns (uint) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    //Calculates total amount of 'asset' held by the system. Vault, strategy and contracts it deposits in.
    
    function totalAssets() public view override returns (uint) {
        return asset.balanceOf(address(this)) + IStrategy(strategy).balanceOf();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS 
    //////////////////////////////////////////////////////////////*/

    function setDelay(uint128 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.InvalidDelay();}
        delay = _delay;
    }
    
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

        uint amount = ERC20(_token).balanceOf(address(this));
        ERC20(_token).safeTransfer(msg.sender, amount);

        emit StuckTokens(msg.sender, amount, _token);
    }

    /*//////////////////////////////////////////////////////////////
                               UNUSED
    //////////////////////////////////////////////////////////////
    
    Following functions are included as per EIP-4626 standard but are not meant
    To be used in the context of this vault. As such, they were made void by design.
    This vault does not allow 3rd parties to deposit or withdraw for another Owner */
    function redeem(uint shares, address receiver, address _owner) public pure override returns (uint) {if(!false){revert XpandrErrors.UnusedFunction();}}
    function mint(uint shares, address receiver) public pure override returns (uint) {if(!false){revert XpandrErrors.UnusedFunction();}}
    function previewMint(uint shares) public pure override returns (uint){if(!false){revert XpandrErrors.UnusedFunction();}}
    function maxRedeem(address _owner) public pure override returns (uint) {if(!false){revert XpandrErrors.UnusedFunction();}}
}