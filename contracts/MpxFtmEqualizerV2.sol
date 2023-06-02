// SPDX-License-Identifier: No License (None)
// No permissions granted before Sunday, 5th May 2024, then GPL-3.0 after this date.

/** 
@title  - MpxFtmEqualizerV2
@author - Nikar0 
@notice - Example Strategy to be used with Xpandr4626 Vault
Includes: feeToken switch / 0% withdraw fee default / Feeds total profit to vault in USD / Harvest buffer/ Adjustable platform fee for promotional events w/ max cap.

https://www.github.com/nikar0/Xpandr4626

Using solmate's gas optimized libs
https://github.com/transmissions11/solmate

@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.

*/

pragma solidity ^0.8.19;

import {Pauser} from "./interfaces/Pauser.sol";
import {ERC20} from "./interfaces/solmate/ERC20.sol";
import {SafeTransferLib} from "./interfaces/solady/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";

contract MpxFtmEqualizerV2 is AccessControl, Pauser {
   
    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/

    event Harvest(address indexed harvester);
    event SetVault(address indexed newVault);
    event RouterSetGaugeSet(address indexed router, address indexed gauge);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event SlippageSetDelaySet(uint8 slippage, uint64 delay);
    event HarvestOnDepositSet(uint8 harvestOnDeposit);
    event RemoveStrat(address indexed caller);
    event Panic(address indexed caller);
    event CustomTx(address indexed from, uint indexed amount);

    // Tokens
    address internal constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address internal constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address internal constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address public asset;
    address[] public rewardTokens;
    address[3] internal slippageLPs;

    // Third party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public feeRecipient;
    address public vault; 

    // Fee Structure
    uint64 internal constant FEE_DIVISOR = 1000;
    uint64 public platformFee = 35;                         // 3.5% Platform fee max cap
    uint64 public withdrawFee;                             // 0% withdraw fee. Kept in case of economic attacks, can only be set to 0 or 0.1%
    uint64 public treasuryFee = 590;
    uint64 public callFee = 120;
    uint64 public stratFee = 290;  
    uint64 public recipientFee;

    // Controllers
    uint64 internal lastHarvest;
    uint64 internal harvestProfit;
    uint64 internal delay;
    uint8 internal harvestOnDeposit;
    uint8 internal slippage;


    constructor(
        address _asset,
        address _gauge,
        address _router,
        address _strategist
    ) {
        asset = _asset;
        gauge = _gauge;
        router = _router;
        strategist = _strategist;
        emit SetStrategist(address(0), _strategist);

        slippageLPs = [address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122), address(asset), address(0x7547d05dFf1DA6B4A2eBB3f0833aFE3C62ABD9a1)];
        rewardTokens.push(equal);
        lastHarvest = uint64(block.timestamp);
        delay = 600; // 10 mins
        _addAllowance();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function deposit() public whenNotPaused {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        harvestProfit = 0;
        uint assetBal = SafeTransferLib.balanceOf(asset, address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    function withdraw(uint _amount) external {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        uint assetBal = SafeTransferLib.balanceOf(asset, address(this));

        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
            assetBal = SafeTransferLib.balanceOf(asset, address(this));             
        }

        if (assetBal > _amount) {
            assetBal = _amount;
        }
        if(withdrawFee != 0){
            uint withdrawalFeeAmount = assetBal * withdrawFee / FEE_DIVISOR; 
            SafeTransferLib.safeTransfer(asset, vault, assetBal - withdrawalFeeAmount);
        } else {SafeTransferLib.safeTransfer(asset, vault, assetBal);}
    }

    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(_timestamp() < lastHarvest + delay){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        if (caller != vault){
            if(caller != tx.origin){revert XpandrErrors.NotEOA();}
        }
        emit Harvest(caller);

        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint rewardBal = SafeTransferLib.balanceOf(equal, address(this));

        if (rewardBal != 0 ) {
            _chargeFees(caller);
            _addLiquidity();
        }
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _chargeFees(address caller) internal {                   
        uint equalBal = SafeTransferLib.balanceOf(equal, address(this));
        uint minAmt = getSlippage(equalBal, slippageLPs[0], equal);
        IEqualizerRouter(router).swapExactTokensForTokensSimple(equalBal, minAmt, equal, wftm, false, address(this), lastHarvest);
        
        uint feeBal = SafeTransferLib.balanceOf(wftm, address(this)) * platformFee / FEE_DIVISOR;
        uint toProfit = SafeTransferLib.balanceOf(wftm, address(this)) - feeBal;

        uint usdProfit = IEqualizerPair(slippageLPs[2]).sample(wftm, toProfit, 1, 1)[0];
        harvestProfit = harvestProfit + uint64(usdProfit);

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, caller, callAmt);

        if(recipientFee != 0){
        uint recipientAmt = feeBal * recipientFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, feeRecipient, recipientAmt);
        }

        uint treasuryAmt = feeBal * treasuryFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, treasury, treasuryAmt);
                                                
        uint stratAmt = feeBal * stratFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, strategist, stratAmt);
    }

    function _addLiquidity() internal {
        uint wftmHalf = SafeTransferLib.balanceOf(wftm, address(this)) >> 1;
        (uint minAmt) = getSlippage(wftmHalf, address(asset), wftm);
        IEqualizerRouter(router).swapExactTokensForTokensSimple(wftmHalf, minAmt, wftm, mpx, false, address(this), lastHarvest);

        uint t1Bal = SafeTransferLib.balanceOf(wftm, address(this));
        uint t2Bal = SafeTransferLib.balanceOf(mpx, address(this));
        IEqualizerRouter(router).addLiquidity(wftm, mpx, false, t1Bal, t2Bal, 1, 1, address(this), lastHarvest);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    //Determines the amount of reward in native upon calling the harvest function
    function callReward() external view returns (uint) {
        uint outputBal = IEqualizerGauge(gauge).earned(equal, address(this));
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * platformFee / FEE_DIVISOR * callFee / FEE_DIVISOR;
    }

    //Returns rewards unharvested
    function rewardBalance() external view returns (uint) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    //Return the total underlying 'asset' held by the strat */
    function balanceOf() external view returns (uint) {
        return balanceOfAsset() + (balanceOfPool());
    }

    //Return 'asset' balance this contract holds
    function balanceOfAsset() public view returns (uint) {
        return ERC20(asset).balanceOf(address(this));
    }

    //Return how much 'asset' the strategy has working in the farm
    function balanceOfPool() public view returns (uint) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    function harvestProfits() external view returns (uint64){
        return harvestProfit / 1e6;
    }

    function getSlippageGetDelay() external view returns (uint8 percentage, uint64 buffer){
        return (slippage, delay);
    }

    /*//////////////////////////////////////////////////////////////
                        SECURITY & UPGRADE 
    //////////////////////////////////////////////////////////////*/

    //Called as part of strat migration. Sends all available funds back to the vault
    function removeStrat() external {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        _harvest(msg.sender);
        IEqualizerGauge(gauge).withdraw(balanceOfPool());
        ERC20(asset).transfer(vault, balanceOfAsset());

        emit RemoveStrat(msg.sender);
    }

    //Pauses the strategy contract & executes emergency withdraw
    function panic() external onlyAdmin {
        pause();
        emit Panic(msg.sender);
        IEqualizerGauge(gauge).withdraw(balanceOfPool());
    }

    function pause() public onlyAdmin {
        _pause();
        _subAllowance();
    }

    function unpause() external whenPaused onlyAdmin {
        _unpause();
        _addAllowance();
        deposit();
    }

    //Guards against timestamp spoofing
    function _timestamp() internal view returns (uint64 timestamp){
        uint lastBlock = IEqualizerPair(slippageLPs[2]).blockTimestampLast();
        timestamp = uint64(lastBlock + 300);
    }

    function getSlippage(uint _amount, address _lp, address _token) internal view returns(uint minAmt){
        uint[] memory t1Amts = IEqualizerPair(_lp).sample(_token, _amount, 2, 1);
        minAmt = (t1Amts[0] + t1Amts[1] ) / 2;
        minAmt = minAmt - (minAmt *  slippage / 100);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _platformFee, uint64 _callFee, uint64 _stratFee, uint64 _withdrawFee, uint64 _treasuryFee, uint64 _recipientFee, address _recipient) external onlyAdmin {
        if(_platformFee > 35){revert XpandrErrors.OverCap();}
        if(_withdrawFee != 0 || _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _recipientFee;
        if(sum > FEE_DIVISOR){revert XpandrErrors.OverCap();}
        if(feeRecipient != address(0) && feeRecipient != _recipient){feeRecipient = _recipient;}

        platformFee = _platformFee;
        callFee = _callFee;
        stratFee = _stratFee;
        withdrawFee = _withdrawFee;
        treasuryFee = _treasuryFee;
        recipientFee = _recipientFee;
        emit SetFeesAndRecipient(_withdrawFee, sum, feeRecipient);
    }

    function setVault(address _vault) external onlyOwner {
        if(_vault == address(0)){revert XpandrErrors.ZeroAddress();}
        vault = _vault;
        emit SetVault(_vault);
    }

    function setRouterOrGauge(address _router, address _gauge) external onlyOwner {
        if(_router == address(0) || _gauge == address(0)){revert XpandrErrors.ZeroAddress();}
        if(_router != router){router = _router;}
        if(_gauge != gauge){gauge = _gauge;}
        emit RouterSetGaugeSet(router, gauge);
    }

    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 || _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
        emit HarvestOnDepositSet(harvestOnDeposit);
    } 

    function setSlippageSetDelay(uint8 _slippage, uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.InvalidDelay();}
        if(_slippage > 5 || _slippage < 1){revert XpandrErrors.OverCap();}

        if(_delay != delay){delay = _delay;}
        if(_slippage != slippage){slippage = _slippage;}
        emit SlippageSetDelaySet(slippage, delay);
    }
    
    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////

    This function exists for cases where a vault may receive sporadic 3rd party rewards such as airdrop from it's deposit in a farm.
    Enables convert that token into more of this vault's reward. */ 
    function customTx(address _token, uint _amount, IEqualizerRouter.Routes[] memory _path) external onlyAdmin {
        if(_token == equal || _token == wftm || _token == mpx){revert XpandrErrors.InvalidTokenOrPath();}
        uint bal;
        if(_amount == 0) {bal = SafeTransferLib.balanceOf(_token, address(this));}
        else {bal = _amount;}
        emit CustomTx(_token, bal);

        SafeTransferLib.safeApprove(_token, router, 0);
        SafeTransferLib.safeApprove(_token, router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 1, _path, address(this), _timestamp());   
    }

    function _subAllowance() internal {
        SafeTransferLib.safeApprove(asset, gauge, 0);
        SafeTransferLib.safeApprove(equal, router, 0);
        SafeTransferLib.safeApprove(wftm, router, 0);
        SafeTransferLib.safeApprove(mpx, router, 0);
    }

    function _addAllowance() internal {
        SafeTransferLib.safeApprove(asset, gauge, type(uint).max);
        SafeTransferLib.safeApprove(equal, router, type(uint).max);
        SafeTransferLib.safeApprove(wftm, router, type(uint).max);
        SafeTransferLib.safeApprove(mpx, router, type(uint).max);
    }

    //Called by vault if harvestOnDeposit = 1
    function afterDeposit() external whenNotPaused {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
            _harvest(tx.origin);
    }

}