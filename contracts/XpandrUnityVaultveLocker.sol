// SPDX-License-Identifier: No License (None)
// No permissions granted before June 1st 2026, then GPL-3.0 after this date.

/** 
@title  - XpandrUnityVaultveLocker
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract.
          Includes: 0% withdraw fee default / Vault profit in USD / Deposit & harvest buffers / Timestamp & Slippage protection
          This vault locks rewards into depositor assigned veNFT.

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


@notice - AccessControl = modified OZ Ownable.sol v4 w/ added onlyAdmin and harvesters modifiers + error codes.
        - Pauser = modified OZ Pausable.sol using uint8 instead of bool + error codes.
**/

pragma solidity 0.8.19;

import {ERC20, ERC4626, FixedPointMathLib} from "./interfaces/solmate/ERC4626light.sol";
import {SafeTransferLib} from "./interfaces/solady/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";
import {IveEqual} from "./interfaces/IveEqual.sol";

// Equalizer EQUAL-pEQUAL veLocker//

contract XpandrUnityVaultveLocker is ERC4626, AccessControl, Pauser {
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event Harvest(address indexed harvester);
    event GaugeSet(address indexed newGauge);
    event Panic(address indexed caller);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event TimestampSourceSet(address indexed newTimestampSource);
    event DelaySet(uint64 delay);
    event CustomTx(address indexed from, uint indexed amount);
    event StuckTokens(address indexed caller, uint indexed amount, address indexed token);
    
    // Tokens
    address internal constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address internal constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address[] internal rewardTokens;
    address[2] internal slippageLPs;
    address[] internal depositorAddresses;

    // 3rd party contracts
    address public gauge;
    address public router;
    address public constant veEqual = address(0x8313f3551C4D3984FfbaDFb42f780D0c8763Ce94);
    address internal timestampSource;                         // Used as timestamp source for deadlines.

    // Xpandr addresses
    address public feeRecipient;

    // Fee Structure
    uint64 internal constant FEE_DIVISOR = 1000;               
    uint64 public constant platformFee = 35;                // 3.5% Platform fee cap
    uint64 public withdrawFee;                              // 0% withdraw fee. Logic kept in case spam/economic attacks bypass buffers, can only be set to 0 or 0.1%
    uint64 public treasuryFee = 600;
    uint64 public callFee = 120;
    uint64 public stratFee = 280;  
    uint64 public recipientFee;

    // Controllers
    uint256 totalQueue;
    uint64 internal lastHarvest;                            // Safeguard only allows harvest being called if > delay
    uint64 internal vaultProfit;                            // Excludes performance fees
    uint64 internal delay;                                  // Part of deposit and harvest buffers
    uint256 internal constant PROFIT_TOKEN_PER_SHARE_PRECISION = 1e24;
    uint256 public accProfitTokenPerShare;
    struct UserInfo {
    uint rewardDebt;
    uint amount;
    uint nftId;
    }
                        
    mapping(address => uint64) internal lastUserDeposit;    //Safeguard only allows same user deposits if > delay
    mapping(address => UserInfo) public userInfo;   
    mapping(address => bool) internal isDeposited;
    mapping(address => uint) internal queuePosition;


    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        address _timestampSource,
        address _strategist
        )
       ERC4626(
            _asset,
            string(abi.encodePacked("XPANDR EQUAL-pEQUAL EQUALIZER")),
            string(abi.encodePacked("XpE-EQUAL-pEQUAL"))
        ) payable
        {
        gauge = _gauge;
        router = _router;
        strategist = _strategist;
        emit SetStrategist(address(0), strategist);
        delay = 600; // 10 mins
        timestampSource = _timestampSource;

        slippageLPs = [address(0x77CfeE25570b291b0882F68Bac770Abf512c2b5C), address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122)]; //Used to calculate slippage and get vaultProfit in usd which is displayed in UI.
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
        if(msg.sender != receiver){revert XpandrErrors.NotAccountOwner();}
        UserInfo storage user = userInfo[receiver];
        if(user.nftId == 0){revert XpandrErrors.ZeroAmount();}

        uint64 timestamp = _timestamp();
        if(lastUserDeposit[receiver] != 0) {if(timestamp < lastUserDeposit[receiver] + delay) {revert XpandrErrors.UnderTimeLock();}}
        shares = convertToShares(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}

        if(!isDeposited[receiver]){
            isDeposited[receiver] = true;
            depositorAddresses.push(receiver);
            totalQueue = totalQueue + 1;
        }

        lastUserDeposit[receiver] = timestamp;
        emit Deposit(receiver, receiver, assets, shares);
        SafeTransferLib.safeTransferFrom(address(asset), receiver, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _mint(receiver, shares);

        uint userAmt = SafeTransferLib.balanceOf(address(this), msg.sender);
        user.amount = user.amount + shares;
        user.rewardDebt = (userAmt * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;

        _earn();
    }

    function withdrawAll() external {
        withdraw(SafeTransferLib.balanceOf(address(this), msg.sender), msg.sender, msg.sender);
    }

    // Withdraw 'asset' from farm into vault & sends to receiver.
    function withdraw(uint shares, address receiver, address _owner) public nonReentrant override returns (uint assets) {
        if(msg.sender != receiver || msg.sender != _owner){revert XpandrErrors.NotAccountOwner();}
        assets = convertToAssets(shares);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
        UserInfo storage user = userInfo[msg.sender];

        _burn(_owner, shares);
        uint userShareBal = SafeTransferLib.balanceOf(address(this), _owner);
        if(userShareBal == 0){
            isDeposited[receiver] = false;
            delete depositorAddresses[queuePosition[receiver]];
            queuePosition[receiver] = 0;
            totalQueue = totalQueue - 1;
            user.nftId = 0;
            user.amount = 0;
        } else {user.amount = user.amount - shares;}
        user.rewardDebt = (userShareBal * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;

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
        uint64 buffer = _timestamp();
        if(buffer < lastHarvest + delay){revert XpandrErrors.UnderTimeLock();}
        lastHarvest = buffer;
        _harvest(msg.sender);
    }
    
    //Ensures that if timestampSource ever fails it can still harvest using block.timestamp for deadlines.
    function adminHarvest() external harvesters {
        lastHarvest = uint64(block.timestamp);
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        emit Harvest(caller);
        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint outputBal = SafeTransferLib.balanceOf(equal, address(this));

        if (outputBal != 0 ) {
            _chargeFees(caller);
            _distroToNfts();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    function getUserPendingEarnings(address depositor) internal view returns (uint pending) {
        uint userAmt = SafeTransferLib.balanceOf(address(this), depositor);
        if (userAmt == 0 || accProfitTokenPerShare == 0) {return 0;}
        UserInfo storage user = userInfo[depositor];
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

    //Deducts fees, adds to vaultProfit & tx fees to receivers.
    function _chargeFees(address caller) internal {                   
        uint equalBal = SafeTransferLib.balanceOf(equal, address(this));
        uint feeBal = equalBal * platformFee / FEE_DIVISOR;
        uint minAmt = IEqualizerPair(slippageLPs[1]).sample(equal, equalBal - feeBal, 1, 1)[0];

    
        uint64 usdProfit = uint64(IEqualizerPair(slippageLPs[0]).sample(wftm, minAmt, 1, 1)[0]);
        vaultProfit = vaultProfit + usdProfit;

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(equal, caller, callAmt);

        if(recipientFee != 0){
        uint recipientAmt = feeBal * recipientFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(equal, feeRecipient, recipientAmt);
        }

        uint treasuryAmt = feeBal * treasuryFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(equal, treasury, treasuryAmt);
                                                
        uint stratAmt = feeBal * stratFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(equal, strategist, stratAmt);
    }

    function _distroToNfts() internal {
        uint equalbal = SafeTransferLib.balanceOf(equal, address(this));
        accProfitTokenPerShare = accProfitTokenPerShare + ((equalbal * PROFIT_TOKEN_PER_SHARE_PRECISION) / totalSupply);
        
        for(uint i = 0; i < totalQueue - 1;){
        if(depositorAddresses[i] == address(0)){continue;}
        UserInfo storage user = userInfo[depositorAddresses[i]];

        if(user.nftId == 0){continue;}
        uint pending = getUserPendingEarnings(msg.sender);
        if (pending == 0) {continue;}
        user.rewardDebt = (user.amount * accProfitTokenPerShare) / PROFIT_TOKEN_PER_SHARE_PRECISION;
        IveEqual(veEqual).deposit_for(user.nftId, user.rewardDebt);
        unchecked {++i;}
        } 
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

    function idleFunds() public view returns (uint) {
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
    
    //Conversion from LP to shares when depositing.
    function convertToShares(uint assets) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    //Function name in the ERC4626 standard is previewMint, renamed to have a similar naming to what's used in deposit
    function convertToAssets(uint shares) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    //Returns USD value generated to depositors (exclusding fees) to be displayed in the UI.
    function vaultProfits() external view returns (uint64){
        return vaultProfit / 1e6;
    }

    //Returns current values for slippage and delay
    function getDelay() external view returns (uint64){
        return (delay);
    }

    //Returns user based pending earnings
    function pendingEarnings(address receiver) external view returns (uint) {
        return getUserPendingEarnings(receiver);
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
        if(idleFunds() != 0){ _earn();}
    }

    // Guards against timestamp spoofing
    function _timestamp() internal view returns (uint64 timestamp){
        uint64 lastBlock = uint64(IEqualizerPair(timestampSource).blockTimestampLast());
        timestamp = lastBlock + delay;
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setProfitTokenPerShare(uint256 _amount) internal {
        uint256 totalShares = totalSupply;
        if (totalShares == 0) {
        return;
        }
        accProfitTokenPerShare += ((_amount * PROFIT_TOKEN_PER_SHARE_PRECISION) / totalShares);
    }

    //Assigns veNFT id to be linked with depositor's address.
    function assignNFT(uint id) external {
        if(id == 0){revert XpandrErrors.ZeroAmount();}
        if(IveEqual(equal).ownerOf(id) == address(0)){revert XpandrErrors.ZeroAddress();}
        UserInfo storage user = userInfo[msg.sender];
        user.nftId = id;
    }

    //Sets fee scheme. withdrawFee capped at 1.
    function setFeesAndRecipient(uint64 _withdrawFee, uint64 _callFee, uint64 _treasuryFee, uint64 _stratFee, uint64 _recipientFee, address _recipient) external onlyAdmin {
        if(_withdrawFee > 1){revert XpandrErrors.OverCap();}
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

    function setGauge(address _gauge) external onlyOwner {
        if(_gauge == address(0)){revert XpandrErrors.ZeroAddress();}
        if(_gauge != gauge){gauge = _gauge;}
        emit GaugeSet(gauge);
    }

    function SetDelay(uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.OverCap();}
        if(_delay != delay){delay = _delay;}
        emit DelaySet(delay);
    }

    function setTimestampSource(address source) external onlyAdmin{
        if(source == address(0)){revert XpandrErrors.ZeroAddress();}
        if(timestampSource != source){timestampSource = source;}
        emit TimestampSourceSet(source);
    }

    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////

    This function exists for cases where a vault may receive sporadic 3rd party rewards such as airdrop from it's deposit in a farm.
    Enables converting that token into more of this vault's reward. */ 
    function customTx(address _token, uint _amount, IEqualizerRouter.Routes[] memory _path) external onlyOwner {
        if(_token == equal || _token == wftm) {revert XpandrErrors.InvalidTokenOrPath();}
        uint bal;
        if(_amount == 0) {bal = SafeTransferLib.balanceOf(_token, address(this));}
        else {bal = _amount;}
        
        emit CustomTx(_token, bal);
        SafeTransferLib.safeApprove(_token, router, 0);
        SafeTransferLib.safeApprove(_token, router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokens(bal, 1, _path, address(this), block.timestamp);
    }

    //Rescues random funds stuck that the vault can't handle.
    function stuckTokens(address _token, uint _amount) external onlyAdmin {
        if(ERC20(_token) == asset || _token == equal){revert XpandrErrors.InvalidTokenOrPath();}
        uint amount;
        if(_amount == 0){amount = SafeTransferLib.balanceOf(_token, address(this));}  else {amount = _amount;}
        emit StuckTokens(msg.sender, amount, _token);
        SafeTransferLib.safeTransfer(_token, msg.sender, amount);
    }

    function _subAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, 0);
        SafeTransferLib.safeApprove(equal, veEqual, 0);
    }

    function _addAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, type(uint).max);
        SafeTransferLib.safeApprove(equal, veEqual, type(uint).max);
    }

    //ERC4626 hook. Unused in this build
    function afterDeposit(uint64 timestamp, uint shares) internal override {
      revert XpandrErrors.InvalidTokenOrPath();
    }
}