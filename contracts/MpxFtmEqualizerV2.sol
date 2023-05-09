//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/solmate/ERC20.sol";
import "./interfaces/solmate/SafeTransferLib.sol";
import "./interfaces/AdminOwned.sol";
import "./interfaces/IEqualizerRouter.sol";
import "./interfaces/IEqualizerGauge.sol";
import "./interfaces/XpandrErrors.sol";

contract MpxFtmEqualizerV2 is AdminOwned, Pausable, XpandrErrors {
    using SafeTransferLib for ERC20;

    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address public asset;
    address public feeToken;
    address[] public rewardTokens;

    // Third party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public constant harvester = address(0xb8924595019aFB894150a9C7CBEc3362999b9f94);
    address public treasury = address(0xfAE236b4E261278C2B84e74b4631cf7BCAFca06d);
    address public feeRecipient;
    address public vault; 

    //Routes
    IEqualizerRouter.Routes[] public equalToWftmPath;
    IEqualizerRouter.Routes[] public equalToMpxPath;
    IEqualizerRouter.Routes[] public feeTokenPath;
    IEqualizerRouter.Routes[] public customPath;

    // Controllers
    bool public constant stable = false;
    uint256 public profit;
    uint8 public harvestOnDeposit;
    uint64 internal lastHarvest;

    // Fee structure
    uint256 public constant FEE_DIVISOR = 500;
    uint256 public constant PLATFORM_FEE = 35;               // 3.5% Platform fee 
    uint256 public WITHDRAW_FEE = 0;                         // 0% of withdrawal amount. Kept in case of economic attacks.
    uint256 public TREASURY_FEE = 590;
    uint256 public CALL_FEE = 120;
    uint256 public STRAT_FEE = 290;  
    uint256 public RECIPIENT_FEE;

    // Events
    event Harvest(address indexed harvester);
    event SetVault(address indexed newVault);
    event SetFeeRecipient(address indexed newRecipient);
    event SetFeeToken(address indexed newFeeToken);
    event RetireStrat(address indexed caller);
    event Panic(address indexed caller);
    event MakeCustomTxn(address indexed from, address indexed to, uint256 indexed amount);
    event SetFees(uint256 indexed withdrawFee, uint256 indexed totalFees);


    constructor(
        address _asset,
        address _gauge,
        address _router,
        address _feeToken,
        IEqualizerRouter.Routes[] memory _equalToWftmPath,
        IEqualizerRouter.Routes[] memory _equalToMpxPath,
        IEqualizerRouter.Routes[] memory _feeTokenPath
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

        for (uint i; i < _feeTokenPath.length; ++i) {
            feeTokenPath.push(_feeTokenPath[i]);
        }

        rewardTokens.push(equal);
        harvestOnDeposit = 0;
        lastHarvest = uint64(block.timestamp);
        _addAllowance();
        
    }

    //Called by vault if harvestOnDeposit = 1
    function afterDeposit() external whenNotPaused {
        if(msg.sender != vault){revert NotVault();}
            _harvest(tx.origin);
    }

    function deposit() public whenNotPaused {
        if(msg.sender != vault){revert NotVault();}
        _deposit();
    }

    function _deposit() internal whenNotPaused {
        uint256 assetBal = ERC20(asset).balanceOf(address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    function withdraw(uint256 _amount) external {
        if(msg.sender != vault){revert NotVault();}

        uint256 assetBal = ERC20(asset).balanceOf(address(this));

        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
            assetBal = ERC20(asset).balanceOf(address(this));             
        }

        if (assetBal > _amount) {
            assetBal = _amount;
        }

        uint256 withdrawalFeeAmount = assetBal * WITHDRAW_FEE >> FEE_DIVISOR;
        ERC20(asset).safeTransfer(vault, assetBal - withdrawalFeeAmount);
    }

    function harvest() external {
        if(msg.sender != tx.origin){revert NotEOA();}
        if(lastHarvest < uint64(block.timestamp + 600)){revert UnderTimeLock();}
        _harvest(msg.sender);
    }

    /** @dev Compounds the strategy's earnings and charges fees */
    function _harvest(address caller) internal whenNotPaused {
        if (caller != vault){
            if(caller != tx.origin){revert NotEOA();}
        }

        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint256 outputBal = ERC20(equal).balanceOf(address(this));
        profit = profit + outputBal;

        if (outputBal > 0 ) {
            _chargeFees(caller);
            _addLiquidity();
        }
        _deposit();

        emit Harvest(caller);
    }
    /** @dev This function converts all funds to WFTM, charges fees and sends fees to respective accounts */
    function _chargeFees(address caller) internal {                   
       uint256 toFee = ERC20(equal).balanceOf(address(this)) * PLATFORM_FEE >> FEE_DIVISOR;

        if(feeToken != equal){IEqualizerRouter(router).swapExactTokensForTokens(toFee, 0, feeTokenPath, address(this), uint64(block.timestamp));}
    
        uint256 feeBal = ERC20(feeToken).balanceOf(address(this));   

        if(feeToken == equal){ _distroRewardFee(feeBal, caller);
        } else {_distroFee(feeBal, caller);}
    }

    /** @dev Converts WMFTM to both sides of the LP token and builds the liquidity pair */
    function _addLiquidity() internal {
        uint256 equalHalf = ERC20(equal).balanceOf(address(this)) >> 1;

        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToWftmPath, address(this), uint64(block.timestamp));
        IEqualizerRouter(router).swapExactTokensForTokens(equalHalf, 0, equalToMpxPath, address(this), uint64(block.timestamp));

        uint256 t1Bal = ERC20(wftm).balanceOf(address(this));
        uint256 t2Bal = ERC20(mpx).balanceOf(address(this));

        uint256 liquidity;
        (,,liquidity) = IEqualizerRouter(router).addLiquidity(wftm, mpx, stable, t1Bal, t2Bal, 1, 1, address(this), uint64(block.timestamp));
        profit = profit + liquidity;    
    }


    /** @dev Determines the amount of reward in WFTM upon calling the harvest function */
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardBalance();
        uint256 wrappedOut;
        if (outputBal > 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * PLATFORM_FEE >> FEE_DIVISOR * CALL_FEE >> FEE_DIVISOR;
    }

    // returns rewards unharvested
    function rewardBalance() public view returns (uint256) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    /** @dev calculate the total underlying 'asset' held by the strat */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + (balanceOfPool());
    }

    //Returns 'asset' balance this contract holds
    function balanceOfWant() public view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    //Returns how much 'asset' the strategy has working in the farm
    function balanceOfPool() public view returns (uint256) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    //Called as part of strat migration. Sends all available funds back to the vault
    function retireStrat() external {
        if(msg.sender != vault){revert NotVault();}
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

    /** @dev Removes allowances to spenders */
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

    /** @dev This function exists incase tokens that do not match the {asset} of this strategy accrue.  For example: an amount of
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

    // Sets the fee amounts
    function setFees(uint256 newCallFee, uint256 newStratFee, uint256 newWithdrawFee, uint256 newTreasuryFee, uint256 newRecipientFee) external onlyAdmin {
        if(newWithdrawFee > 1){revert OverMaxFee();}
        uint256 sum = newCallFee + newStratFee + newTreasuryFee + newRecipientFee;
        if(sum > FEE_DIVISOR){revert OverFeeDiv();}

        CALL_FEE = newCallFee;
        STRAT_FEE = newStratFee;
        WITHDRAW_FEE = newWithdrawFee;
        TREASURY_FEE = newTreasuryFee;
        RECIPIENT_FEE = newRecipientFee;

        emit SetFees(newWithdrawFee, sum);
    }

    // Sets the vault connected to this strategy
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
        emit SetVault(_vault);
    }

    // Sets the grimFeeRecipient address
    function setFeeRecipient(address _feeRecipient) external onlyAdmin {
        feeRecipient = _feeRecipient;
        emit SetFeeRecipient(_feeRecipient);
    }

   function setFeeToken(address _feeToken, IEqualizerRouter.Routes[] memory _feeTokenPath) external onlyAdmin {
       if(_feeToken == address(0) || _feeTokenPath.length == 0){revert InvalidTokenOrPath();}
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
}