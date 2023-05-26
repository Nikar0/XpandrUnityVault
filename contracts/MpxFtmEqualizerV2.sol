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
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";

contract MpxFtmEqualizerV2 is AccessControl, Pauser {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/

    event Harvest(address indexed harvester);
    event SetVault(address indexed newVault);
    event SetRouterOrGauge(address indexed router, address indexed gauge);
    event SetFeeToken(address indexed newFeeToken);
    event SetPaths(IEqualizerRouter.Routes[] indexed path1, IEqualizerRouter.Routes[] indexed path2);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event RemoveStrat(address indexed caller);
    event SetDelay(uint64 delay);
    event Panic(address indexed caller);
    event CustomTx(address indexed from, uint indexed amount);

    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address public asset;
    address internal feeToken;
    address[] public rewardTokens;
    address[2] internal slippageTokens;
    address[2] internal slippageLPs;

    // Third party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public feeRecipient;
    address public vault; 

    // Paths
    IEqualizerRouter.Routes[] public equalToWftmPath;
    IEqualizerRouter.Routes[] public equalToMpxPath;
    IEqualizerRouter.Routes[] public customPath;

    // Fee Structure
    uint64 public constant FEE_DIVISOR = 1000;
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
    uint8 public harvestOnDeposit;


    constructor(
        address _asset,
        address _gauge,
        address _router,
        address _feeToken,
        address _strategist,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath
    ) {
        asset = _asset;
        gauge = _gauge;
        router = _router;
        feeToken = _feeToken;
        strategist = _strategist;
        emit SetStrategist(address(0), _strategist);

        for (uint i; i < _equalToWftmPath.length; ++i) {
            equalToWftmPath.push(_equalToWftmPath[i]);
        }

        for (uint i; i < _equalToMpxPath.length; ++i) {
            equalToMpxPath.push(_equalToMpxPath[i]);
        }
        slippageTokens = [equal, wftm];
        slippageLPs = [address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122), address(_asset)];
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
        uint assetBal = ERC20(asset).balanceOf(address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    function withdraw(uint _amount) external {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        uint assetBal = ERC20(asset).balanceOf(address(this));

        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
            assetBal = ERC20(asset).balanceOf(address(this));             
        }

        if (assetBal > _amount) {
            assetBal = _amount;
        }
        if(withdrawFee != 0){
            uint withdrawalFeeAmount = assetBal * withdrawFee / FEE_DIVISOR; 
            ERC20(asset).safeTransfer(vault, assetBal - withdrawalFeeAmount);
        } else {ERC20(asset).safeTransfer(vault, assetBal);}
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
        uint rewardBal = ERC20(equal).balanceOf(address(this));

        uint toProfit = rewardBal - (rewardBal * platformFee / FEE_DIVISOR);
        (uint profitBal,) = IEqualizerRouter(router).getAmountOut(toProfit, equal, usdc);
        harvestProfit = harvestProfit + uint64(profitBal * 1e6 / 1e12);

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
        uint toFee = ERC20(equal).balanceOf(address(this)) * platformFee / FEE_DIVISOR;
        IEqualizerRouter(router).swapExactTokensForTokensSimple(toFee, 1, equal, feeToken, false, address(this), lastHarvest);
    
        uint feeBal = ERC20(feeToken).balanceOf(address(this));

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        ERC20(feeToken).transfer(caller, callAmt);

        if(recipientFee != 0){
        uint recipientAmt = feeBal * recipientFee / FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(feeRecipient, recipientAmt);
        }

        uint treasuryAmt = feeBal * treasuryFee / FEE_DIVISOR;
        ERC20(feeToken).transfer(treasury, treasuryAmt);
                                                
        uint stratAmt = feeBal * stratFee / FEE_DIVISOR;
        ERC20(feeToken).transfer(strategist, stratAmt);
    }

    function _addLiquidity() internal {
        uint equalHalf = ERC20(equal).balanceOf(address(this)) >> 1;
        (uint minAmt1, uint minAmt2) = slippage(equalHalf);
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, minAmt1, equalToWftmPath, address(this), lastHarvest);
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, minAmt2, equalToMpxPath, address(this), lastHarvest);

        uint t1Bal = ERC20(wftm).balanceOf(address(this));
        uint t2Bal = ERC20(mpx).balanceOf(address(this));

        IEqualizerRouter(router).addLiquidity(wftm, mpx, false, t1Bal, t2Bal, 1, 1, address(this), lastHarvest);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    //Determines the amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint) {
        uint outputBal = rewardBalance();
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * platformFee / FEE_DIVISOR * callFee / FEE_DIVISOR;
    }

    //Returns rewards unharvested
    function rewardBalance() public view returns (uint) {
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
        return harvestProfit;
    }

    function getDelay() external view returns(uint64){
        return delay;
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
        (,,uint lastBlock) = (IEqualizerPair(address(asset)).getReserves());
        timestamp = uint64(lastBlock + 600);
    }

    //Guards against sandwich attacks
    function slippage(uint _amount) internal view returns(uint minAmt1, uint minAmt2){
        uint[] memory t1Amts = IEqualizerPair(slippageLPs[0]).sample(slippageTokens[0], _amount, 3, 2);
        minAmt1 = (t1Amts[0] + t1Amts[1] + t1Amts[2]) / 3;

        uint[] memory t2Amts = IEqualizerPair(slippageLPs[1]).sample(slippageTokens[1], minAmt1, 3, 2);
        minAmt1 = minAmt1 - (minAmt1 *  2 / 100);

        minAmt2 = (t2Amts[0] + t2Amts[1] + t2Amts[2]) / 3;
        minAmt2 = minAmt2 - (minAmt2 * 2 / 100);
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
        emit SetRouterOrGauge(router, gauge);
    }

    function setPaths(IEqualizerRouter.Routes[] memory _equalToMpx, IEqualizerRouter.Routes[] memory _equalToWftm) external onlyAdmin{
        if(_equalToMpx.length != 0){
            for (uint i; i < _equalToMpx.length; ++i) {
            equalToMpxPath.push(_equalToMpx[i]);
            }
        }
        if(_equalToWftm.length != 0){
            for (uint i; i < _equalToWftm.length; ++i) {
            equalToWftmPath.push(_equalToWftm[i]);
            }
        }
        emit SetPaths(equalToMpxPath, equalToWftmPath);
    }

    function setFeeToken(address _feeToken) external onlyAdmin {
       if(_feeToken == address(0) || _feeToken == feeToken){revert XpandrErrors.InvalidTokenOrPath();}
       feeToken = _feeToken;
       emit SetFeeToken(_feeToken);

       ERC20(_feeToken).safeApprove(router, 0);
       ERC20(_feeToken).safeApprove(router, type(uint).max);
    }

    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 || _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
    } 

    function setDelay(uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.InvalidDelay();}
        delay = _delay;
    }
    
    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////

    This function exists for cases where a vault may receive sporadic 3rd party rewards such as airdrop from it's deposit in a farm.
    Enables convert that token into more of this vault's reward. */ 
    function customTx(address _token, uint _amount, IEqualizerRouter.Routes[] memory _path) external onlyAdmin {
        if(_token == equal || _token == wftm || _token == mpx){revert XpandrErrors.InvalidTokenOrPath();}
        uint bal;
        if(_amount == 0) {bal = ERC20(_token).balanceOf(address(this));}
        else {bal = _amount;}

        for (uint i; i < _path.length; ++i) {
            customPath.push(_path[i]);
        }

        ERC20(_token).safeApprove(router, 0);
        ERC20(_token).safeApprove(router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 1, customPath, address(this), _timestamp());   
    }

    function _subAllowance() internal {
        ERC20(asset).safeApprove(gauge, 0);
        ERC20(equal).safeApprove(router, 0);
        ERC20(wftm).safeApprove(router, 0);
        ERC20(mpx).safeApprove(router, 0);
    }

    function _addAllowance() internal {
        ERC20(asset).safeApprove(gauge, type(uint).max);
        ERC20(equal).safeApprove(router, type(uint).max);
        ERC20(wftm).safeApprove(router, type(uint).max);
        ERC20(mpx).safeApprove(router, type(uint).max);
    }

    //Called by vault if harvestOnDeposit = 1
    function afterDeposit() external whenNotPaused {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
            _harvest(tx.origin);
    }

}