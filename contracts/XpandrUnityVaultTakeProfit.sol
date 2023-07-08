// SPDX-License-Identifier: No License (None)
// No permissions granted before June 1st 2025, then GPL-3.0 after this date.

/** 
@title  - XpandrUnityTakeProfit
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract. Sells reward to claimable USDC.
          Includes: 0% withdraw fee default / Vault profit in USD / Deposit & harvest buffers / Timestamp & Slippage protection

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


Vault based on EIP-4626
https://eips.ethereum.org/EIPS/eip-4626

Take Profit embedded from @JaeTask Ninja Yielder vauls, with due permission.
https://docs.yielder.ninja/assets/audits/20230112_TrustSecurityAudit_V3Vaults_v02_signed.pdf

Using solmate libs for ERC20, ERC4626
https://github.com/transmissions11/solmate

Using solady SafeTransferLib
https://github.com/Vectorized/solady/


@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.
        - Pauser = modified OZ Pausable.sol using uint8 instead of bool + error codes.
**/

pragma solidity ^0.8.19;

import {ERC20, ERC4626, FixedPointMathLib} from "./interfaces/solmate/ERC4626light.sol";
import {SafeTransferLib} from "./interfaces/solady/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";

contract XpandrUnityVaultTakeProfit is ERC4626, AccessControl, Pauser {
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event Harvest(address indexed harvester);
    event RouterSetGaugeSet(address indexed newRouter, address indexed newGauge);
    event Panic(address indexed caller);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event SetSlippageSetDelaySet(uint8 slippage, uint64 delay);
    event CustomTx(address indexed from, uint indexed amount);
    event StuckTokens(address indexed caller, uint indexed amount, address indexed token);
    event WithdrawProfit(address indexed user, uint amount);
    event Reinvest(address indexed receiver, uint lpAmt, uint shareAmt);
   
    // Tokens
    address internal constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address internal constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address[] internal rewardTokens;
    address[3] internal slippageLPs;

    // 3rd party contracts
    address public gauge;
    address public router;
    address internal timestampSource;

    //Paths
    IEqualizerRouter.Routes[] public equalToUsdcPath;
    IEqualizerRouter.Routes[] public usdcToEqualPath;

    // Xpandr addresses
    address public feeRecipient;
    address internal royaltyRecipient;
    IRewarder public rewarder;

    // Fee Structure
    uint256 internal constant PROFIT_TOKEN_PER_SHARE_PRECISION = 1e24;
    uint64 internal constant FEE_DIVISOR = 1000;               
    uint64 public constant platformFee = 40;                // 4% Platform fee cap for Take Profit vaults.
    uint64 public withdrawFee;                              // 0% withdraw fee. Logic kept in case spam/economic attacks bypass buffers, can only be set to 0 or 0.1%
    uint64 public treasuryFee = 500;
    uint64 public callFee = 125;
    uint64 public stratFee = 200;
    uint64 public royaltyFee = 125;  
    uint64 public recipientFee;

    // Controllers
    struct UserInfo {
    uint256 rewardDebt;
    }
    uint256 public accProfitTokenPerShare;
    uint256 internal float;
    uint64 internal lastHarvest;                            // Safeguard only allows harvest being called if > delay
    uint64 internal vaultProfit;                            // Excludes performance fees
    uint64 internal delay;
    uint8 internal harvestOnDeposit; 
    uint8 internal slippage;       
    uint8 internal constant slippageDiv = 100;                     
    mapping(address => UserInfo) public userInfo;   
    mapping(address => uint64) internal lastUserDeposit;    //Safeguard only allows same user deposits if > delay

    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        uint8 _slippage,
        address _strategist,
        address _timestampSource,
        IEqualizerRouter.Routes[] memory _equalToUsdcPath,
        IEqualizerRouter.Routes[] memory _usdcToEqualPath
        )
       ERC4626(
            _asset,
            string(abi.encodePacked("XPANDR EQUAL-FTM TAKE PROFIT")),
            string(abi.encodePacked("XpE-EQUAL-FTM-TP"))
        )
        {
        gauge = _gauge;
        router = _router;
        strategist = _strategist;
        emit SetStrategist(address(0), strategist);
        delay = 600; // 10 mins
        slippage = _slippage;
        timestampSource = _timestampSource;

        for (uint i; i < _equalToUsdcPath.length; ++i) {
            equalToUsdcPath.push(_equalToUsdcPath[i]);
        }
        for (uint i; i < _usdcToEqualPath.length; ++i) {
            usdcToEqualPath.push(_usdcToEqualPath[i]);
        }
        
        slippageLPs = [address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122), address(_asset), address(0x7547d05dFf1DA6B4A2eBB3f0833aFE3C62ABD9a1)];
        rewardTokens.push(equal);
        lastHarvest = uint64(block.timestamp);
        _addAllowance();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function depositAll() external {
        deposit(SafeTransferLib.balanceOf(address(asset), msg.sender), msg.sender);
    }

    // Deposit 'asset' into the vault which then deposits funds into the farm.  
    function deposit(uint assets, address receiver) public override whenNotPaused returns (uint shares) {
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}
        if(lastUserDeposit[receiver] != 0) {if(_timestamp() < lastUserDeposit[receiver] + delay) {revert XpandrErrors.UnderTimeLock();}}
        if(assets > SafeTransferLib.balanceOf(address(asset), receiver)){revert XpandrErrors.OverCap();}
        shares = convertToShares(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}

        lastUserDeposit[receiver] = _timestamp();
        uint pending = getUserPendingEarnings(receiver);
        UserInfo storage user = userInfo[receiver];
        uint userAmt = balanceOf(msg.sender);
        user.rewardDebt = (userAmt * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;

        if (address(rewarder) != address(0)) {
           uint userAssetBal = getUserUnderlyingBalance(receiver);
           rewarder.onReward(0, receiver, receiver, pending, userAssetBal);
        }
        
        if (pending != 0) {
        SafeTransferLib.safeTransfer(usdc, receiver, pending);
        }
        emit Deposit(receiver, receiver, assets, shares);

        SafeTransferLib.safeTransferFrom(address(asset), receiver, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _mint(receiver, shares);
        _earn();

        if(harvestOnDeposit != 0) {afterDeposit(assets, shares);}
    }

    function withdrawAll() external {
        withdraw(SafeTransferLib.balanceOf(address(this), msg.sender), msg.sender, msg.sender);
    }

    // Withdraw 'asset' from farm into vault & sends to receiver.
    function withdraw(uint shares, address receiver, address _owner) public override returns (uint assets) {
        if(tx.origin != receiver && tx.origin != _owner){revert XpandrErrors.NotAccountOwner();}
        if(shares > SafeTransferLib.balanceOf(address(this), _owner)){revert XpandrErrors.OverCap();}
        assets = convertToAssets(shares);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}

        uint pending = getUserPendingEarnings(msg.sender);
        uint userAmount = balanceOf(msg.sender);
        user.rewardDebt = (userAmount * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;

        if (pending != 0) {SafeTransferLib.safeTransfer(usdc, msg.sender, pending);}

        if (address(rewarder) != address(0)){
           uint256 userUnderlyingBalance = getUserUnderlyingBalance(msg.sender);
           rewarder.onReward(0, msg.sender, msg.sender, pending, userUnderlyingBalance);
        }
       
        _burn(_owner, shares);
        emit Withdraw(_owner, receiver, _owner, assets, shares);
        _collect(assets);

        uint assetBal = SafeTransferLib.balanceOf(address(asset), address(this));
        if (assetBal > assets) {assetBal = assets;}

        if(withdrawFee != 0){
            uint withdrawFeeAmt = assetBal * withdrawFee / FEE_DIVISOR;
            SafeTransferLib.safeTransfer(address(asset), receiver, assetBal - withdrawFeeAmt);
        } else {SafeTransferLib.safeTransfer(address(asset), receiver, assetBal);}
    }

    function withdrawProfit() external {
        UserInfo storage user = userInfo[msg.sender];
        uint userAmt = balanceOf(msg.sender);
        if (userAmt == 0) {revert XpandrErrors.ZeroAmount();}

        uint pending = getUserPendingEarnings(msg.sender);
        if (pending != 0) {
          user.rewardDebt = (userAmt * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;
           
            if (address(rewarder) != address(0)) {
             uint256 userUnderlyingBalance = getUserUnderlyingBalance(msg.sender);
             rewarder.onReward(0, msg.sender, msg.sender, pending, userUnderlyingBalance);
            }
            
          SafeTransferLib.safeTransfer(usdc, msg.sender, pending);
          emit WithdrawProfit(msg.sender, pending);
        }
    }

    function reinvest() external {
        uint userAmt = balanceOf(msg.sender);
        if (userAmt == 0) {revert XpandrErrors.ZeroAmount();}
        UserInfo storage user = userInfo[msg.sender];
        uint pending = getUserPendingEarnings(msg.sender);

        if (pending != 0) {
           user.rewardDebt = (userAmt * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;
           uint timestamp = _timestamp();

           uint halfProfit = pending >> 1;
           uint minAmtWftm = getSlippage(halfProfit, slippageLPs[0], usdc);
           uint minAmtEqual = getSlippage(minAmtWftm, address(this), wftm);

           IEqualizerRouter(router).swapExactTokensForTokensSimple(halfProfit, minAmtWftm, usdc, wftm, false, address(this), timestamp);
           IEqualizerRouter(router).swapExactTokensForTokens(halfProfit, minAmtEqual, usdcToEqualPath, address(this), timestamp);

           uint t1Bal = SafeTransferLib.balanceOf(wftm, address(this));
           uint t2Bal = SafeTransferLib.balanceOf(equal, address(this));
           (uint t1Min, uint t2Min,) = IEqualizerRouter(router).quoteAddLiquidity(wftm, equal, false, t1Bal, t2Bal);
           IEqualizerRouter(router).addLiquidity(wftm, equal, false, t1Bal, t2Bal, t1Min * slippage / slippageDiv, t2Min * slippage / slippageDiv, address(this), timestamp);

           uint lpToDeposit = SafeTransferLib.balanceOf(address(asset), address(this));
           uint toMint = convertToShares(lpToDeposit);
           emit Reinvest(msg.sender, lpToDeposit, toMint);
           _earn();
           _mint(msg.sender, toMint);
        }
    }


    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(_timestamp() < lastHarvest + delay){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        lastHarvest = _timestamp();
        emit Harvest(caller);
        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint outputBal = SafeTransferLib.balanceOf(equal, address(this));

        if (outputBal != 0 ) {
            _takeFeesTakeProfit(caller);
            _setProfitTokenPerShare(float);
        }
        _earn();
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    function getUserPendingEarnings(address receiver) internal view returns (uint pending) {
        uint userAmt = balanceOf(receiver);
        if (userAmt == 0 || accProfitTokenPerShare == 0) {return 0;}
        UserInfo storage user = userInfo[receiver];
        pending = (userAmt * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION - user.rewardDebt;
    }

    // Deposits funds in the farm
    function _earn() internal {
        uint assetBal = SafeTransferLib.balanceOf(address(asset), address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    // Withdraws funds from the farm
    function _collect(uint _amount) internal {
        uint assetBal = SafeTransferLib.balanceOf(address(asset), address(this));
        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
        }
    }

    function _takeFeesTakeProfit(address caller) internal {     
        uint profitPool = SafeTransferLib.balanceOf(usdc, address(this));              
        uint equalBal = SafeTransferLib.balanceOf(equal, address(this));
        uint minAmtOut = getSlippage(equalBal, slippageLPs[2], equal);
        IEqualizerRouter(router).swapExactTokensForTokens(equalBal, minAmtOut, equalToUsdcPath, address(this), lastHarvest);

        uint yield = SafeTransferLib.balanceOf(usdc, address(this)) - profitPool;
        uint feeBal = yield * platformFee / FEE_DIVISOR;
        uint toProfit = yield - feeBal;
        float = toProfit;
        vaultProfit = vaultProfit + uint64(toProfit);

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(usdc, caller, callAmt);

        if(recipientFee != 0){
        uint recipientAmt = feeBal * recipientFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(usdc, feeRecipient, recipientAmt);
        }

        uint treasuryAmt = feeBal * treasuryFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(usdc, treasury, treasuryAmt);
                                                
        uint stratAmt = feeBal * stratFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(usdc, strategist, stratAmt);

        uint royaltyAmt = feeBal * royaltyFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(usdc, royaltyRecipient, royaltyAmt);
    }

    function setProfitTokenPerShare(uint256 _amount) internal {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) {
        return;
        }
        accProfitTokenPerShare += ((_amount * PROFIT_TOKEN_PER_SHARE_PRECISION) / totalShares);
        float = 0;
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    // Returns amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint) {
        uint outputBal = IEqualizerGauge(gauge).earned(equal, address(this));
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * platformFee / FEE_DIVISOR * callFee / FEE_DIVISOR;
    }

    function pendingEarnings(address receiver) external view returns (uint) {
        return getUserPendingEarnings(receiver);
    }

    function idleFunds() external view returns (uint) {
        return SafeTransferLib.balanceOf(address(asset), address(this));
    }
    
    // Returns total amount of 'asset' held by the vault and contracts it deposits in.
    function totalAssets() public view override returns (uint) {
        return SafeTransferLib.balanceOf(address(asset), address(this)) + balanceOfPool();
    }

    //Return how much 'asset' the vault has working in the farm
    function balanceOfPool() public view returns (uint) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    // Returns rewards unharvested
    function rewardBalance() external view returns (uint) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    // Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() external view returns (uint) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    function convertToShares(uint assets) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint shares) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function vaultProfits() external view returns (uint64){
        return vaultProfit / 1e6;
    }

    function getSlippageGetDelay() external view returns (uint8 _slippage, uint64 buffer){
        return (slippage, delay);
    }

    /*//////////////////////////////////////////////////////////////
                             SECURITY
    //////////////////////////////////////////////////////////////*/

    // Pauses the vault & executes emergency withdraw
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
        _earn();
    }

    //Guards against timestamp spoofing
    function _timestamp() internal view returns (uint64 timestamp){
        uint lastBlock = IEqualizerPair(timestampSource).blockTimestampLast();
        timestamp = uint64(lastBlock + 300);
    }

    //Slippage protection for swaps
    function getSlippage(uint _amount, address _lp, address _token) internal view returns(uint minAmt){
        uint[] memory t1Amts = IEqualizerPair(_lp).sample(_token, _amount, 2, 1);
        minAmt = (t1Amts[0] + t1Amts[1] ) / 2;
        minAmt = minAmt - (minAmt *  slippage / slippageDiv);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _withdrawFee, uint64 _callFee, uint64 _treasuryFee, uint64 _stratFee, uint64 _recipientFee, uint64 _royaltyFee, address _recipient) external onlyAdmin {
        if(_withdrawFee != 0 && _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _royaltyFee + _recipientFee;
        if(sum > FEE_DIVISOR){revert XpandrErrors.OverCap();}
        if(_recipient != address(0) && _recipient != feeRecipient){feeRecipient = _recipient;}

        callFee = _callFee;
        stratFee = _stratFee;
        withdrawFee = _withdrawFee;
        treasuryFee = _treasuryFee;
        royaltyFee = _royaltyFee;
        recipientFee = _recipientFee;
        emit SetFeesAndRecipient(withdrawFee, sum, feeRecipient);
    }

    function setRouterSetGauge(address _router, address _gauge) external onlyOwner {
        if(_router == address(0) || _gauge == address(0)){revert XpandrErrors.ZeroAddress();}
        if(_router != router){router = _router;}
        if(_gauge != gauge){gauge = _gauge;}
        emit RouterSetGaugeSet(router, gauge);
    }

    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 && _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
    } 

    function setSlippageSetDelay(uint8 _slippage, uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.OverCap();}
        if(_slippage > 5 || _slippage < 1){revert XpandrErrors.OverCap();}

        if(_delay != delay){delay = _delay;}
        if(_slippage != slippage){slippage = _slippage;}
        emit SetSlippageSetDelaySet(slippage, delay);
    }

    function setTimestampSource(address source) external onlyAdmin{
        if(source == address(0)){revert XpandrErrors.ZeroAddress();}
        if(slippageLPs[0] != source){slippageLPs[0] = source;}
    }

    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////

    This function exists for cases where a vault may receive sporadic 3rd party rewards such as airdrop from it's deposit in a farm.
    Enables convert that token into more of this vault's reward. */ 
    function customTx(address _token, uint _amount, IEqualizerRouter.Routes[] memory _path) external onlyOwner {
        if(_token == equal || _token == wftm || _token == usdc){revert XpandrErrors.InvalidTokenOrPath();}
        uint bal;
        if(_amount == 0) {bal = SafeTransferLib.balanceOf(_token, address(this));}
        else {bal = _amount;}
        
        emit CustomTx(_token, bal);
        SafeTransferLib.safeApprove(_token, router, 0);
        SafeTransferLib.safeApprove(_token, router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 1, _path, address(this), _timestamp());
    }

    //Rescues random funds stuck that the vault can't handle.
    function stuckTokens(address _token, uint _amount) external onlyOwner {
        if(ERC20(_token) == asset || _token == usdc){revert XpandrErrors.InvalidTokenOrPath();}
        uint amount;
        if(_amount == 0){amount = SafeTransferLib.balanceOf(_token, address(this));}  else {amount = _amount;}
        emit StuckTokens(msg.sender, amount, _token);
        SafeTransferLib.safeTransfer(_token, msg.sender, amount);
    }

    function _subAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, 0);
        SafeTransferLib.safeApprove(equal, router, 0);
        SafeTransferLib.safeApprove(wftm, router, 0);
        SafeTransferLib.safeApprove(usdc, router, 0);
    }

    function _addAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, type(uint).max);
        SafeTransferLib.safeApprove(equal, router, type(uint).max);
        SafeTransferLib.safeApprove(wftm, router, type(uint).max);
        SafeTransferLib.safeApprove(usdc, router, type(uint).max);
    }

    //ERC4626 hook. Called by deposit if harvestOnDeposit = 1. Args unused but part of spec
    function afterDeposit(uint assets, uint shares) internal override {
        _harvest(tx.origin);
    }
}