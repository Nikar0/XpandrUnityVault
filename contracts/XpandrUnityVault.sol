// SPDX-License-Identifier: No License (None)
// No permissions granted before Sunday, 5th May 2025, then GPL-3.0 after this date.

/** 
@title  - XpandrUnityVault
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract.
          Includes: feeToken switch / 0% withdraw fee default / Vault profit in USD /
          Deposit & harvest buffers / Timestamp & Slippage protection /

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


Vault based on EIP-4626 by @joey_santoro, @transmissions11, et all.
https://eips.ethereum.org/EIPS/eip-4626

Using solmate libs for ERC20, ERC4626
https://github.com/transmissions11/solmate

Using solady SafeTransferLib
https://github.com/Vectorized/solady/

Special thanks to 543 from Equalizer/Guru_Network for the brainstorming & QA

@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.
        - Pauser = modified OZ Pausable.sol using uint8 instead of bool + error codes.
**/

pragma solidity ^0.8.19;

import {ERC20, ERC4626, FixedPointMathLib} from "./interfaces/solmate/ERC4626light.sol";
import {SafeTransferLib} from "./interfaces/solady/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";

contract XpandrUnityVault is ERC4626, AccessControl, Pauser {
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event Harvest(address indexed harvester);
    event SetRouterOrGauge(address indexed newRouter, address indexed newGauge);
    event SetFeeToken(address indexed newFeeToken, IEqualizerRouter.Routes[] indexed _path);
    event SetPaths(IEqualizerRouter.Routes[] indexed path1, IEqualizerRouter.Routes[] indexed path2);
    event Panic(address indexed caller);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event DelaySet(uint64 delay);
    event SlippageSet(uint8 percent);
    event CustomTx(address indexed from, uint indexed amount);
    event StuckTokens(address indexed caller, uint indexed amount, address indexed token);
    
    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address internal feeToken;        // Switch for which token protocol receives fees in. In mind for Native & Stable but fits any Equal - X token swap.
    address[] internal rewardTokens;
    address[2] internal slippageTokens;
    address[3] internal slippageLPs;

    // 3rd party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public feeRecipient;

    // Paths
    IEqualizerRouter.Routes[] public equalToWftmPath;
    IEqualizerRouter.Routes[] public equalToMpxPath;
    IEqualizerRouter.Routes[] public feeTokenPath;

    // Fee Structure
    uint64 public constant FEE_DIVISOR = 1000;               
    uint64 public constant platformFee = 35;                // 3.5% Platform fee cap
    uint64 public withdrawFee;                              // 0% withdraw fee. Logic kept in case spam/economic attacks bypass buffers, can only be set to 0 or 0.1%
    uint64 public treasuryFee = 590;
    uint64 public callFee = 120;
    uint64 public stratFee = 290;  
    uint64 public recipientFee;

    // Controllers
    uint64 internal lastHarvest;                            // Safeguard only allows harvest being called if > delay
    uint64 internal vaultProfit;                            // Excludes performance fees
    uint64 internal delay;
    uint8 internal harvestOnDeposit; 
    uint8 internal percent;                                   
    mapping(address => uint64) internal lastUserDeposit;    //Safeguard only allows same user deposits if > delay

    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        uint8 _percent,
        address _feeToken,
        address _strategist,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath,
        IEqualizerRouter.Routes[] memory _feeTokenPath
        )
       ERC4626(
            _asset,
            string(abi.encodePacked("Tester Vault")),
            string(abi.encodePacked("LP"))
        )
        {
        gauge = _gauge;
        router = _router;
        feeToken = _feeToken;
        strategist = _strategist;
        emit SetStrategist(address(0), strategist);
        delay = 600; // 10 mins
        percent = _percent;

        for (uint i; i < _equalToWftmPath.length;) {
            equalToWftmPath.push(_equalToWftmPath[i]);
            unchecked{++i;}
        }

        for (uint i; i < _equalToMpxPath.length;) {
            equalToMpxPath.push(_equalToMpxPath[i]);
            unchecked{++i;}
        }

        for (uint i; i < _feeTokenPath.length;) {
            feeTokenPath.push(_feeTokenPath[i]);
            unchecked{++i;}
        }

        slippageTokens = [equal, wftm];
        slippageLPs = [address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122), address(_asset), address(0x76fa7935a5AFEf7fefF1C88bA858808133058908)];
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
            _chargeFees(caller);
            _addLiquidity();
        }
        _earn();
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

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

    function _chargeFees(address caller) internal {                   
        uint toFee = SafeTransferLib.balanceOf(address(equal), address(this)) * platformFee / FEE_DIVISOR;
        uint toProfit = SafeTransferLib.balanceOf(address(equal), address(this)) - toFee;

        (uint usdProfit) = IEqualizerPair(slippageLPs[2]).sample(equal, toProfit, 1, 1)[0];
        vaultProfit = vaultProfit + uint64(usdProfit * 1e6);

        IEqualizerRouter(router).swapExactTokensForTokens(toFee, 1, feeTokenPath, address(this), lastHarvest);

        uint feeBal = SafeTransferLib.balanceOf(feeToken, address(this));

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(feeToken, caller, callAmt);

        if(recipientFee != 0){
        uint recipientAmt = feeBal * recipientFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(feeToken, feeRecipient, recipientAmt);
        }

        uint treasuryAmt = feeBal * treasuryFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(feeToken, treasury, treasuryAmt);
                                                
        uint stratAmt = feeBal * stratFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(feeToken, strategist, stratAmt);
    }

    function _addLiquidity() internal {
        uint equalHalf = SafeTransferLib.balanceOf(equal, address(this)) >> 1;
        (uint minAmt1, uint minAmt2) = slippage(equalHalf);
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, minAmt1, equalToWftmPath, address(this), lastHarvest);
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, minAmt2, equalToMpxPath, address(this), lastHarvest);

        uint t1Bal = SafeTransferLib.balanceOf(wftm, address(this));
        uint t2Bal = SafeTransferLib.balanceOf(mpx, address(this));
        IEqualizerRouter(router).addLiquidity(wftm, mpx, false, t1Bal, t2Bal, 1, 1, address(this), lastHarvest);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    // Returns amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint) {
        uint outputBal = rewardBalance();
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * platformFee / FEE_DIVISOR * callFee / FEE_DIVISOR;
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
    function rewardBalance() public view returns (uint) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    // Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() external view returns (uint) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function vaultProfits() external view returns (uint64){
        return vaultProfit;
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
        (,,uint lastBlock) = IEqualizerPair(address(asset)).getReserves();
        timestamp = uint64(lastBlock + 800);
    }

    //Guards against sandwich attacks
    function slippage(uint _amount) internal view returns(uint minAmt1, uint minAmt2){
        uint[] memory t1Amts = IEqualizerPair(slippageLPs[0]).sample(slippageTokens[0], _amount, 3, 2);
        minAmt1 = (t1Amts[0] + t1Amts[1] + t1Amts[2]) / 3;

        uint[] memory t2Amts = IEqualizerPair(slippageLPs[1]).sample(slippageTokens[1], minAmt1, 3, 2);
        minAmt1 = minAmt1 - (minAmt1 *  percent / 100);

        minAmt2 = (t2Amts[0] + t2Amts[1] + t2Amts[2]) / 3;
        minAmt2 = minAmt2 - (minAmt2 * percent / 100);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _withdrawFee, uint64 _callFee, uint64 _treasuryFee, uint64 _stratFee, uint64 _recipientFee, address _recipient) external onlyOwner {
        if(_withdrawFee != 0 && _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _recipientFee;
        if(sum > FEE_DIVISOR){revert XpandrErrors.OverCap();}
        if(_recipient != address(0) && _recipient != feeRecipient){feeRecipient = _recipient;}

        callFee = _callFee;
        stratFee = _stratFee;
        withdrawFee = _withdrawFee;
        treasuryFee = _treasuryFee;
        recipientFee = _recipientFee;
        emit SetFeesAndRecipient(withdrawFee, sum, feeRecipient);
    }

    function setRouterOrGauge(address _router, address _gauge) external onlyOwner {
        if(_router == address(0) || _gauge == address(0)){revert XpandrErrors.ZeroAddress();}
        if(_router != router){router = _router;}
        if(_gauge != gauge){gauge = _gauge;}
        emit SetRouterOrGauge(router, gauge);
    }

    function setPaths(IEqualizerRouter.Routes[] memory _equalToMpx, IEqualizerRouter.Routes[] memory _equalToWftm) external onlyAdmin{
        if(_equalToMpx.length != 0){
            for (uint i; i < _equalToMpx.length;) {
            equalToMpxPath.push(_equalToMpx[i]);
            unchecked{++i;}
            }
        }
        if(_equalToWftm.length != 0){
            for (uint i; i < _equalToWftm.length;) {
            equalToWftmPath.push(_equalToWftm[i]);
            unchecked{++i;}
            }
        }
        emit SetPaths(equalToMpxPath, equalToWftmPath);
    }

   function setFeeToken(address _feeToken, IEqualizerRouter.Routes[] memory _path) external onlyAdmin {
       if(_feeToken == address(0) || _feeToken == feeToken){revert XpandrErrors.InvalidTokenOrPath();}
       feeToken = _feeToken;
       if(feeTokenPath.length != 0){
            for (uint i; i < _path.length;) {
            feeTokenPath.push(_path[i]);
            unchecked{++i;}
            }
        }
       emit SetFeeToken(_feeToken, feeTokenPath);
      
       SafeTransferLib.safeApprove(feeToken, router, 0);
       SafeTransferLib.safeApprove(feeToken, router, type(uint).max);
    }

    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 && _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
    } 

    function setDelay(uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.InvalidDelay();}
        delay = _delay;
        emit DelaySet(delay);
    }

    function setSlippage(uint8 _percent) external onlyAdmin {
        if(_percent > 10){revert XpandrErrors.OverCap();}
        percent = percent;
        emit SlippageSet(percent);
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
        SafeTransferLib.safeApprove(address(asset), gauge, 0);
        SafeTransferLib.safeApprove(equal, router, 0);
        SafeTransferLib.safeApprove(wftm, router, 0);
        SafeTransferLib.safeApprove(mpx, router, 0);
    }

    function _addAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, type(uint).max);
        SafeTransferLib.safeApprove(equal, router, type(uint).max);
        SafeTransferLib.safeApprove(wftm, router, type(uint).max);
        SafeTransferLib.safeApprove(mpx, router, type(uint).max);
    }

    //ERC4626 hook. Called by deposit if harvestOnDeposit = 1. Args unused but part of spec
    function afterDeposit(uint assets, uint shares) internal override {
        _harvest(tx.origin);
    }
}