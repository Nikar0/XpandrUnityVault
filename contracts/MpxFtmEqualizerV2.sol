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
    event SetFeesAndRecipient(uint64 indexed withdrawFee, uint64 indexed totalFees, address indexed newRecipient);
    event RetireStrat(address indexed caller);
    event Panic(address indexed caller);
    event CustomTx(address indexed from, uint indexed amount);

    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address public asset;
    address public feeToken;
    address[] public rewardTokens;

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
    uint64 public constant FEE_DIVISOR = 500;
    uint64 public PLATFORM_FEE = 35;                         // 3.5% Platform fee max cap
    uint64 public WITHDRAW_FEE = 0;                         // 0% withdraw fee. Kept in case of economic attacks, can only be set to 0 or 0.1%
    uint64 public TREASURY_FEE = 590;
    uint64 public CALL_FEE = 120;
    uint64 public STRAT_FEE = 290;  
    uint64 public RECIPIENT_FEE;

    // Controllers
    uint64 internal lastHarvest;
    uint128 public harvestProfit;
    uint128 internal delay;
    bool public constant stable = false;
    uint8 public harvestOnDeposit;


    constructor(
        address _asset,
        address _gauge,
        address _router,
        address _feeToken,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath
    ) {
        asset = _asset;
        gauge = _gauge;
        router = _router;
        feeToken = _feeToken;

        for (uint i; i < _equalToWftmPath.length; ++i) {
            equalToWftmPath.push(_equalToWftmPath[i]);
        }

        for (uint i; i < _equalToMpxPath.length; ++i) {
            equalToMpxPath.push(_equalToMpxPath[i]);
        }

        rewardTokens.push(equal);
        harvestOnDeposit = 0;
        lastHarvest = uint64(block.timestamp);
        _addAllowance();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function deposit() public whenNotPaused {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        harvestProfit = 0;
        _deposit();
    }

    function _deposit() internal whenNotPaused {
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
        if(WITHDRAW_FEE != 0){
            uint withdrawalFeeAmount = assetBal * WITHDRAW_FEE >> FEE_DIVISOR; 
            ERC20(asset).safeTransfer(vault, assetBal - withdrawalFeeAmount);
        } else {ERC20(asset).safeTransfer(vault, assetBal);}
    }

    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(lastHarvest < uint64(block.timestamp + delay)){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        if (caller != vault){
            if(caller != tx.origin){revert XpandrErrors.NotEOA();}
        }

        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint rewardBal = ERC20(equal).balanceOf(address(this));

        uint toProfit = rewardBal - (rewardBal * PLATFORM_FEE >> FEE_DIVISOR);
        (uint profitBal,) = IEqualizerRouter(router).getAmountOut(toProfit, equal, usdc);
        harvestProfit = harvestProfit + uint128(profitBal * 1e18);

        if (rewardBal != 0 ) {
            _chargeFees(caller);
            _addLiquidity();
        }
        _deposit();

        emit Harvest(caller);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _chargeFees(address caller) internal {                   
        uint toFee = ERC20(equal).balanceOf(address(this)) * PLATFORM_FEE >> FEE_DIVISOR;
        IEqualizerRouter(router).swapExactTokensForTokensSimple(toFee, 1, equal, feeToken, stable, address(this), uint64(block.timestamp));
    
        uint feeBal = ERC20(feeToken).balanceOf(address(this));

        uint callFee = feeBal * CALL_FEE >> FEE_DIVISOR;
        ERC20(feeToken).transfer(caller, callFee);

        if(RECIPIENT_FEE != 0){
        uint recipientFee = feeBal * RECIPIENT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(feeRecipient, recipientFee);
        }

        uint treasuryFee = feeBal * TREASURY_FEE >> FEE_DIVISOR;
        ERC20(feeToken).transfer(treasury, treasuryFee);
                                                
        uint stratFee = feeBal * STRAT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).transfer(strategist, stratFee);
    }

    function _addLiquidity() internal {
        uint equalHalf = ERC20(equal).balanceOf(address(this)) >> 1;

        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToWftmPath, address(this), uint64(block.timestamp));
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToMpxPath, address(this), uint64(block.timestamp));

        uint t1Bal = ERC20(wftm).balanceOf(address(this));
        uint t2Bal = ERC20(mpx).balanceOf(address(this));

        IEqualizerRouter(router).addLiquidity(wftm, mpx, stable, t1Bal, t2Bal, 1, 1, address(this), uint64(block.timestamp));
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
        return wrappedOut * PLATFORM_FEE >> FEE_DIVISOR * CALL_FEE >> FEE_DIVISOR;
    }

    //Returns rewards unharvested
    function rewardBalance() public view returns (uint) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    //Return the total underlying 'asset' held by the strat */
    function balanceOf() public view returns (uint) {
        return balanceOfWant() + (balanceOfPool());
    }

    //Return 'asset' balance this contract holds
    function balanceOfWant() public view returns (uint) {
        return ERC20(asset).balanceOf(address(this));
    }

    //Return how much 'asset' the strategy has working in the farm
    function balanceOfPool() public view returns (uint) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        STRAT SECURITY & UPGRADE 
    //////////////////////////////////////////////////////////////*/

    //Called as part of strat migration. Sends all available funds back to the vault
    function retireStrat() external {
        if(msg.sender != vault){revert XpandrErrors.NotVault();}
        _harvest(msg.sender);
        IEqualizerGauge(gauge).withdraw(balanceOfPool());
        ERC20(asset).transfer(vault, balanceOfWant());

        emit RetireStrat(msg.sender);
    }

    //Pauses the strategy contract & executes emergency withdraw
    function panic() external onlyAdmin {
        pause();
        IEqualizerGauge(gauge).withdraw(balanceOfPool());
        emit Panic(msg.sender);
    }

    function pause() public onlyAdmin {
        _pause();
        _subAllowance();
    }

    function unpause() external onlyAdmin {
        _unpause();
        _addAllowance();
        _deposit();
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _platformFee, uint64 _callFee, uint64 _stratFee, uint64 _withdrawFee, uint64 _treasuryFee, uint64 _recipientFee, address _recipient) external onlyAdmin {
        if(_platformFee > 35){revert XpandrErrors.OverCap();}
        if(_withdrawFee != 0 || _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _recipientFee;
        //FeeDivisor is halved for divisions with >> 500 instead of / 1000. As such, using correct value for condition check here.
        if(sum > uint16(1000)){revert XpandrErrors.OverCap();}
        if(feeRecipient != address(0) && feeRecipient != _recipient){feeRecipient = _recipient;}

        PLATFORM_FEE = _platformFee;
        CALL_FEE = _callFee;
        STRAT_FEE = _stratFee;
        WITHDRAW_FEE = _withdrawFee;
        TREASURY_FEE = _treasuryFee;
        RECIPIENT_FEE = _recipientFee;

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
   
       ERC20(_feeToken).safeApprove(router, 0);
       ERC20(_feeToken).safeApprove(router, type(uint).max);
       emit SetFeeToken(_feeToken);
    }

    
    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 || _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
    } 

    function setDelay(uint128 _delay) external onlyAdmin{
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
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 0, customPath, address(this), uint64(block.timestamp));
   
        emit CustomTx(_token, bal);
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