//SPDX-License-Identifier: MIT

/** 
@title Xpandr4626Vault
@author Nikar0 
@notice Minimal, streamlined and gas considerate unified Vault + Stragegy contract


Vault based on EIP 4626 by @Joey_Stantoro, @transmissions11, et all

www.github.com/nikar0/Xpandr4626 - www.twitter.com/Nikar0_
**/

pragma solidity 0.8.17;

import {ERC20, ERC4626} from "./interfaces/solmate/ERC4626.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {ReentrancyGuard} from "./interfaces/solmate//ReentrancyGuard.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {FixedPointMathLib} from "./interfaces/solmate/FixedPointMathLib.sol";
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";

contract Xpandr4626VaultStrat is ERC4626, AccessControl, ReentrancyGuard, Pauser{
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    event Harvest(address indexed harvester);
    event SetFeeRecipient(address indexed newRecipient);
    event SetRouterOrGauge(address indexed newRouter, address indexed newGauge);
    event SetFeeToken(address indexed newFeeToken);
    event SetPaths(IEqualizerRouter.Routes[] indexed path1, IEqualizerRouter.Routes[] indexed path2);
    event Panic(address indexed caller);
    event MakeCustomTxn(address indexed from, address indexed to, uint256 indexed amount);
    event SetFeesAndRecipient(uint64 indexed withdrawFee, uint64 indexed totalFees, address indexed newRecipient);
    event StuckTokens(address indexed caller, uint256 indexed amount, address indexed token);
    
    // Tokens
    address public immutable wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public immutable equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public immutable mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75); //vaultProfit returns USDC value
    address public feeToken;
    address[] public rewardTokens;

    // 3rd party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant harvester = address(0xDFAA88D5d068370689b082D34d7B546CbF393bA9);
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public feeRecipient;

    // Routes
    IEqualizerRouter.Routes[] public equalToWftmPath;
    IEqualizerRouter.Routes[] public equalToMpxPath;
    IEqualizerRouter.Routes[] public feeTokenPath;
    IEqualizerRouter.Routes[] public customPath;

    // Fee Structure
    uint64 public constant FEE_DIVISOR = 500;
    uint64 public constant PLATFORM_FEE = 35;               // 3.5% Platform fee 
    uint64 public WITHDRAW_FEE = 0;                         // 0% of withdrawal amount. Kept in case of spam attacks.
    uint64 public TREASURY_FEE = 590;
    uint64 public CALL_FEE = 120;
    uint64 public STRAT_FEE = 290;  
    uint64 public RECIPIENT_FEE;

    // Controllers
    uint64 internal lastHarvest; 
    uint256 public vaultProfit;
    bool internal constant stable = false;
    uint8 public harvestOnDeposit;
    mapping(address => uint64) internal lastUserDeposit;

    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        address _feeToken,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath,
        IEqualizerRouter.Routes[] memory _feeTokenPath
        )
       ERC4626(
            _asset,
            string(abi.encodePacked("Tester")),
            string(abi.encodePacked("LP"))
        )
        {
        gauge = _gauge;
        router = _router;
        feeToken = _feeToken;

        for (uint i; i < _equalToWftmPath.length; ++i) {
            equalToWftmPath.push(_equalToWftmPath[i]);
        }

        for (uint i; i < _equalToMpxPath.length; ++i) {
            equalToMpxPath.push(_equalToMpxPath[i]);
        }

        for (uint i; i < _feeTokenPath.length; ++i) {
            feeTokenPath.push(_feeTokenPath[i]);
        }

        rewardTokens.push(equal);
        harvestOnDeposit = 0;
        lastHarvest = uint64(block.timestamp);
        totalSupply = type(uint256).max;
        _addAllowance();
        
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/
     function depositAll() external {
        deposit(asset.balanceOf(msg.sender), msg.sender);
    }

    // Entrypoint of funds into the system. The vault then deposits funds into the farm.  
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant() returns (uint256 shares) {
        if(lastUserDeposit[msg.sender] != 0) {if(lastUserDeposit[msg.sender] < uint64(block.timestamp + 600)) {revert XpandrErrors.UnderTimeLock();}}
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}

        shares = previewDeposit(assets);
        if(shares == 0){revert XpandrErrors.ZeroAmount();}

        asset.safeTransferFrom(msg.sender, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _earn();
        lastUserDeposit[msg.sender] = uint64(block.timestamp);
        
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        if(harvestOnDeposit == 1) {afterDeposit(assets, shares);}
    }

    function withdrawAll() external {
        withdraw(asset.balanceOf(msg.sender), msg.sender, msg.sender);
    }

    // Exit point from the system. Collects asset from farm and sends to owner.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256 shares) {
        if(msg.sender != receiver && msg.sender != owner){revert XpandrErrors.NotAccountOwner();}
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}

        shares = previewWithdraw(assets);
        if(shares > ERC20(address(this)).balanceOf(msg.sender)){revert XpandrErrors.OverBalance();}
       
        _collect(assets);
        _burn(owner, shares);

        uint256 assetBal = asset.balanceOf(address(this));
        if (assetBal > assets) {assetBal = assets;}

        if(WITHDRAW_FEE > 0){
            uint256 withdrawFeeAmount = assetBal * WITHDRAW_FEE >> FEE_DIVISOR; 
            asset.safeTransfer(receiver, assetBal - withdrawFeeAmount);
        } else {asset.safeTransfer(receiver, assetBal);}

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(lastHarvest < uint64(block.timestamp + 600)){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        if(caller != tx.origin){revert XpandrErrors.NotEOA();}

        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint256 outputBal = ERC20(equal).balanceOf(address(this));

        (uint256 profitBal,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, usdc);
        vaultProfit = vaultProfit + profitBal;

        if (outputBal > 0 ) {
            _chargeFees(caller);
            _addLiquidity();
        }
        _earn();
        emit Harvest(caller);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    // Deposits funds in the farm
    function _earn() internal {
        uint256 assetBal = asset.balanceOf(address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    // Withdraw funds from the farm
    function _collect(uint256 _amount) internal {
        uint256 assetBal = asset.balanceOf(address(this));
        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
            assetBal = asset.balanceOf(address(this));             
        }
    }

    function _chargeFees(address caller) internal {                   
        uint256 toFee = ERC20(equal).balanceOf(address(this)) * PLATFORM_FEE >> FEE_DIVISOR;

        if(feeToken != equal){IEqualizerRouter(router).swapExactTokensForTokens(toFee, 0, feeTokenPath, address(this), uint64(block.timestamp));}
    
        uint256 feeBal = ERC20(feeToken).balanceOf(address(this));   

        if(feeToken == equal){ _distroRewardFee(feeBal, caller);
        } else {_distroFee(feeBal, caller);}
    }

    function _addLiquidity() internal {
        uint256 equalHalf = ERC20(equal).balanceOf(address(this)) >> 1;

        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToWftmPath, address(this), uint64(block.timestamp));
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToMpxPath, address(this), uint64(block.timestamp));

        uint256 t1Bal = ERC20(wftm).balanceOf(address(this));
        uint256 t2Bal = ERC20(mpx).balanceOf(address(this));

        IEqualizerRouter(router).addLiquidity(wftm, mpx, stable, t1Bal, t2Bal, 1, 1, address(this), uint64(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/
    // Determines the amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardBalance();
        uint256 wrappedOut;
        if (outputBal > 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * PLATFORM_FEE >> FEE_DIVISOR * CALL_FEE >> FEE_DIVISOR;
    }

    function idleFunds() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }
    
    // Returns total amount of 'asset' held by the vault and contracts it deposits in.
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this)) + balanceOfPool();
    }

    //Return how much 'asset' the vault has working in the farm
    function balanceOfPool() public view returns (uint256) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    // Returns rewards unharvested
    function rewardBalance() public view returns (uint256) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    //Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT SECURITY
    //////////////////////////////////////////////////////////////*/
    // Pauses the vault & executes emergency withdraw
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
        _earn();
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/
    function setFeesAndRecipient(uint64 _callFee, uint64 _stratFee, uint64 _withdrawFee, uint64 _treasuryFee, uint64 _recipientFee, address _recipient) external onlyAdmin {
        if(_withdrawFee > 1){revert XpandrErrors.OverMaxFee();}
        uint64 sum = _callFee + _stratFee + _treasuryFee + _recipientFee;
        //FeeDivisor is halved for divisions with >> 500 instead of /1000. As such, must * 2 for correct condition check here.
        if(sum > FEE_DIVISOR * 2){revert XpandrErrors.OverFeeDiv();}
        if(feeRecipient != _recipient){feeRecipient = _recipient;}

        CALL_FEE = _callFee;
        STRAT_FEE = _stratFee;
        WITHDRAW_FEE = _withdrawFee;
        TREASURY_FEE = _treasuryFee;
        RECIPIENT_FEE = _recipientFee;

        emit SetFeesAndRecipient(WITHDRAW_FEE, sum, feeRecipient);
    }

    function setRouterOrGauge(address _router, address _gauge) external onlyOwner {
        if(_router != router){router = _router;}
        if(_gauge != gauge){gauge = _gauge;}
        emit SetRouterOrGauge(router, gauge);
    }

    function setPaths(IEqualizerRouter.Routes[] memory _equalToMpx, IEqualizerRouter.Routes[] memory _equalToWftm) external onlyAdmin{
        if(_equalToMpx.length != 0){
            delete equalToMpxPath;
            for (uint i; i < _equalToMpx.length; ++i) {
            equalToMpxPath.push(_equalToMpx[i]);
            }
        }
        if(_equalToWftm.length != 0){
            delete equalToWftmPath;
            for (uint i; i < _equalToWftm.length; ++i) {
            equalToWftmPath.push(_equalToWftm[i]);
            }
        }
        emit SetPaths(equalToMpxPath, equalToWftmPath);
    }

   function setFeeToken(address _feeToken, IEqualizerRouter.Routes[] memory _feeTokenPath) external onlyAdmin {
       if(_feeToken == address(0) || _feeTokenPath.length == 0){revert XpandrErrors.InvalidTokenOrPath();}
       feeToken = _feeToken;
       delete feeTokenPath;

       for (uint i; i < _feeTokenPath.length; ++i) {
           feeTokenPath.push(_feeTokenPath[i]);
        }

       ERC20(_feeToken).safeApprove(router, 0);
       ERC20(_feeToken).safeApprove(router, type(uint).max);
       emit SetFeeToken(_feeToken);
    }

    // Sets harvestOnDeposit
    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        require(_harvestOnDeposit == 0 || _harvestOnDeposit == 1);
        harvestOnDeposit = _harvestOnDeposit;
    } 
    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////*/

    /** This function exists incase tokens that do not match the {asset} of this strategy accrue.  For example: an amount of
    tokens sent to this address in the form of an airdrop of a different token type. This will allow conversion
    said token to the {output} token of the strategy, allowing the amount to be paid out to stakers in the next harvest. */ 
    function makeCustomTxn(address [][] memory _tokens, bool[] calldata _stable) external onlyAdmin {
        for (uint i; i < _tokens.length; ++i) {
            customPath.push(IEqualizerRouter.Routes({
                from: _tokens[i][0],
                to: _tokens[i][1],
                stable: _stable[i]
            }));
        }
        uint256 bal = ERC20(_tokens[0][0]).balanceOf(address(this));

        ERC20(_tokens[0][0]).safeApprove(router, 0);
        ERC20(_tokens[0][0]).safeApprove(router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokens(bal, 0, customPath, address(this), uint64(block.timestamp + 600));
   
        emit MakeCustomTxn(_tokens[0][0], _tokens[0][_tokens.length - 1], bal);
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
    function afterDeposit(uint256 assets, uint256 shares) internal override whenNotPaused {
         _harvest(tx.origin);
    }

    //Incase fee is taken in native or non reward token
    function _distroFee(uint256 feeBal, address caller) internal {
        uint256 callFee = feeBal * CALL_FEE >> FEE_DIVISOR;        
        ERC20(feeToken).safeTransfer(caller, callFee);

        if(RECIPIENT_FEE >0){
        uint256 recipientFee = feeBal * RECIPIENT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(feeRecipient, recipientFee);
        }

        uint256 treasuryFee = feeBal * TREASURY_FEE >> FEE_DIVISOR;        
        ERC20(feeToken).safeTransfer(treasury, treasuryFee);
                                                
        uint256 stratFee = feeBal * STRAT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(strategist, stratFee); 
    }

    //Incase fee is taken in reward token
    function _distroRewardFee(uint256 feeBal, address caller) internal {
        uint256 rewardFee = feeBal * PLATFORM_FEE >> FEE_DIVISOR; 
    
        uint256 callFee = rewardFee * CALL_FEE >> FEE_DIVISOR;        
        ERC20(feeToken).safeTransfer(caller, callFee);

        if(RECIPIENT_FEE >0){        
        uint256 recipientFee = rewardFee * RECIPIENT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(feeRecipient, recipientFee);
        }

        uint256 treasuryFee = rewardFee * TREASURY_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(treasury, treasuryFee);
                                                
        uint256 stratFee = rewardFee * STRAT_FEE >> FEE_DIVISOR;
        ERC20(feeToken).safeTransfer(strategist, stratFee); 
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