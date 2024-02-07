// SPDX-License-Identifier: No License (None)
// No permissions granted before June 1st 2025, then GPL-3.0 after this date.

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

import {ERC20, ERC4626, FixedPointMathLib} from "../interfaces/solmate/ERC4626light.sol";
import {SafeTransferLib} from "../interfaces/solady/SafeTransferLib.sol";
import {IEqualizerPair} from "../interfaces/IEqualizerPair.sol";
import {XpandrErrors} from "../interfaces/XpandrErrors.sol";
import {AccessControl} from "../interfaces/AccessControl.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
Implementation of a vault to deposit funds for yield optimizing
This is the contract that receives funds & users interface with
The strategy itself is implemented in a separate Strategy contract
 */
contract Xpandr4626 is ERC4626, AccessControl {
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                           VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }

    StratCandidate public stratCandidate;         //The last proposed strategy to switch to.
    IStrategy public strategy;                    //The strategy currently in use by the vault.
    uint64 constant approvalDelay = 43200;       //Delay before a strat can be approved. 12 hours
    uint64 vaultProfit;                            //Sum of the yield earned by strategies attached to the vault. In USD.
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
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function depositAll() external {
        deposit(SafeTransferLib.balanceOf(address(asset), msg.sender), msg.sender);
    }

    //Entrypoint of funds into the system. The vault then deposits funds into the strategy.  
    function deposit(uint assets, address receiver) public override  returns (uint shares) {
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}
        if(lastUserDeposit[receiver] != 0) {if(_timestamp() < lastUserDeposit[receiver] + strategy.getDelay()) {revert XpandrErrors.UnderTimeLock();}}
        if(assets > SafeTransferLib.balanceOf(address(asset), receiver)){revert XpandrErrors.OverCap();}
        shares = convertToShares(assets);
        if(shares == 0 || assets == 0){revert XpandrErrors.ZeroAmount();}

        lastUserDeposit[receiver] = _timestamp();
        emit Deposit(receiver, receiver, assets, shares);
        vaultProfit = vaultProfit + strategy.harvestProfits();

        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _mint(receiver, shares);
        _earn();

        if(strategy.harvestOnDeposit() != 0) {strategy.afterDeposit();}
    }

    //Function to send funds into the strategy then deposits in the farm.
    //It's primarily called by the vault's deposit() function.
    function _earn() internal {
        uint bal = SafeTransferLib.balanceOf(address(asset), address(this));
        SafeTransferLib.safeTransfer(address(asset), address(strategy), bal);
        strategy.deposit();
    }

    function withdrawAll() external {
        withdraw(SafeTransferLib.balanceOf(address(asset), msg.sender), msg.sender, msg.sender);
    }

    /**
     Exit the system. The vault will withdraw the required tokens
     from the strategy and semd to the token holder. A proportional number of receipt
     tokens are burned in the process.
     */

    function withdraw(uint shares, address receiver, address _owner) public override returns (uint assets) {
        if(tx.origin != receiver && tx.origin != _owner){revert XpandrErrors.NotAccountOwner();}
        if(shares > SafeTransferLib.balanceOf(address(this), _owner)){revert XpandrErrors.OverCap();}
        assets = convertToAssets(shares);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
       
        _burn(_owner, shares);
        emit Withdraw(_owner, receiver, _owner, assets, shares);

        strategy.withdraw(assets);
        SafeTransferLib.safeTransfer(address(asset), receiver, assets);

    }

    //Guards against timestamp spoofing
    function _timestamp() internal view returns (uint64 timestamp){
        uint lastBlock = (IEqualizerPair(address(asset)).blockTimestampLast());
        timestamp = uint64(lastBlock + 600);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    //Returns idle funds in the vault
    function idleFunds() public view returns (uint) {
        return SafeTransferLib.balanceOf(address(asset), address(this));
    }

    //Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() public view returns (uint) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    //Calculates total amount of 'asset' held by the system. Vault, strategy and contracts it deposits in.
    
    function totalAssets() public view override returns (uint) {
        return SafeTransferLib.balanceOf(address(asset), address(this)) + IStrategy(strategy).balanceOf();
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }


    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS 
    //////////////////////////////////////////////////////////////*/
    
    //Sets the candidate for the new strat to use with this vault.
    function queueStrat(address _implementation) public onlyAdmin {
        if(address(this) != IStrategy(_implementation).vault()){revert XpandrErrors.InvalidProposal();}
        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: _timestamp()
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
        if(stratCandidate.proposedTime + approvalDelay > _timestamp()){revert XpandrErrors.UnderTimeLock();}

        emit SwapStrat(stratCandidate.implementation);
        strategy.removeStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        _earn();
    }

    //Rescues random funds stuck that the vault can't handle.
    function stuckTokens(address _token, uint _amount) external onlyOwner {
        if(ERC20(_token) == asset){revert XpandrErrors.InvalidTokenOrPath();}
        uint amount;
        if(_amount == 0){amount = SafeTransferLib.balanceOf(_token, address(this));}  else {amount = _amount;}
        emit StuckTokens(msg.sender, amount, _token);
        SafeTransferLib.safeTransfer(_token, msg.sender, amount);
    }

}