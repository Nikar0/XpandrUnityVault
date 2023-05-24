// SPDX-License-Identifier: No License (None)
// No permissions granted before Sunday, 5th May 2024, then GPL-3.0 after this date.

/** 

@title  - XpandrUnityVault
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract.
          Includes: feeToken switch / 0% withdraw fee default / Total Vault profit in USD / Deposit & harvest buffers / Adjustable platform fee for promotional events w/ max cap.

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


Vault based on EIP-4626 by @joey_santoro, @transmissions11, et all.
https://eips.ethereum.org/EIPS/eip-4626

Using solmate's gas optimized libs
https://github.com/transmissions11/solmate

@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.
        - Pauser = modified OZ Pausable.sol using uint8 instead of bool + error codes.
**/

pragma solidity 0.8.19;

import {ERC20, ERC4626, FixedPointMathLib} from "./interfaces/solmate/ERC4626mod.sol";
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";

contract XpandrUnityVault is ERC4626, AccessControl, Pauser{
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event Harvest(address indexed harvester);
    event SetRouterOrGauge(address indexed newRouter, address indexed newGauge);
    event SetFeeToken(address indexed newFeeToken);
    event SetPaths(IEqualizerRouter.Routes[] indexed path1, IEqualizerRouter.Routes[] indexed path2);
    event Panic(address indexed caller);
    event CustomTx(address indexed from, uint indexed amount);
    event SetFeesAndRecipient(uint64 indexed withdrawFee, uint64 indexed totalFees, address indexed newRecipient);
    event StuckTokens(address indexed caller, uint indexed amount, address indexed token);
    
    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address public feeToken;      // Switch for which token protocol receives fees in. In mind for Native & Stable but fits any Equal - X token swap. Streamlines POL portfolio.
    address[] public rewardTokens;

    // 3rd party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public feeRecipient;

    // Paths
    IEqualizerRouter.Routes[] public equalToWftmPath;
    IEqualizerRouter.Routes[] public equalToMpxPath;
    IEqualizerRouter.Routes[] public customPath;

    // Fee Structure
    uint64 public constant FEE_DIVISOR = 500;               // Halved for cheaper divisions with >> 500 instead of / 1000
    uint64 public PLATFORM_FEE = 35;                        // 3.5% Platform fee cap
    uint64 public WITHDRAW_FEE = 0;                         // 0% withdraw fee. Logic kept in case spam/economic attacks bypass buffers, can only be set to 0 or 0.1%
    uint64 public TREASURY_FEE = 590;
    uint64 public CALL_FEE = 120;
    uint64 public STRAT_FEE = 290;  
    uint64 public RECIPIENT_FEE;

    // Controllers
    uint64 internal lastHarvest;                             // Safeguard only allows harvest being called if > delay
    uint128 public vaultProfit;                              // Excludes performance fees
    uint128 public delay;
    bool internal constant stable = false;
    uint8 internal harvestOnDeposit;                                    
    mapping(address => uint64) internal lastUserDeposit;     //Safeguard only allows same user deposits if > delay

    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        address _feeToken,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath
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
        delay = 600; // 10 mins

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

     function depositAll() external {
        deposit(asset.balanceOf(msg.sender), msg.sender);
    }

    // Deposit 'asset' into the vault which then deposits funds into the farm.  
    function deposit(uint assets, address receiver) public override whenNotPaused returns (uint shares) {
        if(lastUserDeposit[msg.sender] != 0) {if(uint64(block.timestamp) < lastUserDeposit[msg.sender] + delay) {revert XpandrErrors.UnderTimeLock();}}
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}
        shares = convertToShares(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
        if(assets > asset.balanceOf(owner)){revert XpandrErrors.OverCap();}

        lastUserDeposit[msg.sender] = uint64(block.timestamp);
        emit Deposit(msg.sender, receiver, assets, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _mint(msg.sender, shares);
        _earn();

        if(harvestOnDeposit == 1) {afterDeposit(assets, shares);}
    }

    function withdrawAll() external {
        withdraw(ERC20(address(this)).balanceOf(msg.sender), msg.sender, msg.sender);
    }

    // Withdraw 'asset' from farm into vault & sends to receiver.
    function withdraw(uint shares, address receiver, address _owner) public override returns (uint assets) {
        if(tx.origin != receiver && tx.origin != _owner){revert XpandrErrors.NotAccountOwner();}
        assets = convertToAssets(shares);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
        if(shares > ERC20(address(this)).balanceOf(_owner)){revert XpandrErrors.OverCap();}
       
        _burn(_owner, shares);
        uint assetBal = asset.balanceOf(address(this));
        if (assetBal > assets) {assetBal = assets;}

        emit Withdraw(msg.sender, receiver, _owner, assetBal, shares);
        _collect(assets);
       
        if(WITHDRAW_FEE != 0){
            uint withdrawFeeAmount = assetBal * WITHDRAW_FEE >> FEE_DIVISOR;
            asset.safeTransfer(receiver, assetBal - withdrawFeeAmount);
        } else {asset.safeTransfer(receiver, assetBal);}
    }

    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(uint64(block.timestamp) < lastHarvest + uint64(delay)){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        emit Harvest(caller);
        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint outputBal = ERC20(equal).balanceOf(address(this));

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
        uint assetBal = asset.balanceOf(address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    // Withdraws funds from the farm
    function _collect(uint _amount) internal {
        uint assetBal = asset.balanceOf(address(this));
        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
        }
    }

    function _chargeFees(address caller) internal {                   
        uint toFee = ERC20(equal).balanceOf(address(this)) * PLATFORM_FEE >> FEE_DIVISOR;
        uint toProfit = ERC20(equal).balanceOf(address(this)) - toFee;

        (uint usdProfit,) = IEqualizerRouter(router).getAmountOut(toProfit, equal, usdc);
        vaultProfit = vaultProfit + uint128(usdProfit * 1e18);

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

    // Returns amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint) {
        uint outputBal = rewardBalance();
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * PLATFORM_FEE >> FEE_DIVISOR * CALL_FEE >> FEE_DIVISOR;
    }

    function idleFunds() external view returns (uint) {
        return asset.balanceOf(address(this));
    }
    
    // Returns total amount of 'asset' held by the vault and contracts it deposits in.
    function totalAssets() public view override returns (uint) {
        return asset.balanceOf(address(this)) + balanceOfPool();
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

    /*//////////////////////////////////////////////////////////////
                            VAULT SECURITY
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

    function unpause() external onlyAdmin {
        _unpause();
        _addAllowance();
        _earn();
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _platformFee, uint64 _callFee, uint64 _stratFee, uint64 _withdrawFee, uint64 _treasuryFee, uint64 _recipientFee, address _recipient) external onlyOwner {
        if(_platformFee > 35){revert XpandrErrors.OverCap();}
        if(_withdrawFee != 0 || _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _recipientFee;
        //FeeDivisor is halved for cheaper divisions with >> 500 instead of 1000. As such, using correct value for condition check here.
        if(sum > uint64(1000)){revert XpandrErrors.OverCap();}
        if(_recipient != address(0) && _recipient != _recipient){feeRecipient = _recipient;}

        emit SetFeesAndRecipient(_withdrawFee, sum, feeRecipient);

        PLATFORM_FEE = _platformFee;
        CALL_FEE = _callFee;
        STRAT_FEE = _stratFee;
        WITHDRAW_FEE = _withdrawFee;
        TREASURY_FEE = _treasuryFee;
        RECIPIENT_FEE = _recipientFee;
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

        emit CustomTx(_token, bal);
        ERC20(_token).safeApprove(router, 0);
        ERC20(_token).safeApprove(router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 0, customPath, address(this), uint64(block.timestamp));
    }

    function _subAllowance() internal {
        asset.safeApprove(gauge, 0);
        ERC20(equal).safeApprove(router, 0);
        ERC20(wftm).safeApprove(router, 0);
        ERC20(mpx).safeApprove(router, 0);
    }

    function _addAllowance() internal {
        asset.safeApprove(gauge, type(uint).max);
        ERC20(equal).safeApprove(router, type(uint).max);
        ERC20(wftm).safeApprove(router, type(uint).max);
        ERC20(mpx).safeApprove(router, type(uint).max);
    }

    //ERC4626 hook. Called by deposit if harvestOnDeposit = 1. Args unused but part of spec
    function afterDeposit(uint assets, uint shares) internal override {
        _harvest(tx.origin);
    }
}