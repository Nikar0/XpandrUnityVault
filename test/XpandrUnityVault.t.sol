// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/XpandrUnityVault.sol";

import {Test, console} from "forge-std/Test.sol";
import {XpandrUnityVault} from "src/XpandrUnityVault.sol";
import {ERC20} from "src/interfaces/solmate/ERC20.sol";
import {IEqualizerRouter} from "src/interfaces/IEqualizerRouter.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";


contract XpandrUnityVaultTest is Test {

  ERC20 asset = ERC20(0x2526F175A088974Cd5a64C4B56Fd4AFab24A50E4);
  XpandrUnityVault vault;
  IEqualizerRouter swapper;
  address public gauge = address(0x5c4D7b40a0eaa4b379C310d38279288E5b66658C);
  address public router =  address(0x33da53f731458d6Bc970B0C5FCBB0b3Db4AAa470);
  address public strategist =  address(0x3C173F1BAF9F97bf244796c0179952a6a2e9C248);
  uint8 public slippage = 2;
  address public timestampSource = address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122);
  address public harvester = address(0xDFAA88D5d068370689b082D34d7B546CbF393bA9);
  address public constant multisig = address(0x3522f55fE566420f14f89bd46820EC66D3A5eb7c);
  uint public lpAmount = 2318483958593833989;
  address legitDepositor = address(this);
  ERC20 unrelatedToken = ERC20(0x97bdAfe3830734acF12Da25359674277fcc33729);
  address stuckTokenOwner = 0xEfC9200cD50ae935DA5d79D122660DDB53620E74;
  address wftm = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
  address equal = 0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6;
  address impersonated = address(0x9324829cCD07B08C8D27096308F37d7cC6EA6edF); // Replace with an account that has a lot of LP tokens
  address equalHolder = 0x6ef2Fa893319dB4A06e864d1dEE17A90fcC34130;
  address unauthorized = 0xDFAA88D5d068370689b082D34d7B546CbF393bA9;


  /*Test Notes 
  For testing to run corretly, change slippage, lastHarvest, harvester & delay to public on contract. 
  */


  function setUp() external {

    // Set the block number to a specific value
    vault = new XpandrUnityVault(asset, gauge, router, slippage, timestampSource, strategist);
    
    vm.startPrank(impersonated);

    // Transfer LP tokens to this contract
    asset.transfer(address(this), lpAmount);

    // Stop impersonating the rich account
    vm.stopPrank();

    asset.approve(address(vault), type(uint).max);
    vault.deposit(lpAmount, legitDepositor);
    unrelatedToken.approve(address(vault), type(uint).max);

    vm.prank(equalHolder);
    ERC20(equal).transfer(address(this), lpAmount);
    vm.stopPrank();
    ERC20(equal).approve(router, type(uint).max);

  }

  //Checks if harvest tx completes and vault balance increases.
  function testadminHarvesting() external {
    uint vaultBeforeBalance = vault.totalAssets();
    uint64 futureStamp = vault.lastHarvest() + 600;
    
    vm.warp(futureStamp);
    vm.prank(strategist);
    vault.adminHarvest();
    vm.stopPrank();

    uint vaultBalanceAfterHarvest = vault.totalAssets();
    console.log("Before Harvest:", vaultBeforeBalance, " After Harvest:", vaultBalanceAfterHarvest);
    assertTrue(vaultBalanceAfterHarvest > vaultBeforeBalance, "Total Assets in vault are higher after harvesting");
    console.log("Harvest successful and totalAssets() increased");

    vm.prank(unauthorized);
    try
    vault.adminHarvest(){}
    catch {
      uint balAfterUnauthorized = vault.totalAssets();
      assertTrue(vaultBalanceAfterHarvest == balAfterUnauthorized);
      console.log("Unauthorized caller has reverted");
    }

  }
  
  //Tests for rounding issues between depositing LP then withdrawing it. Meant to have same LP amount before deposit & after withdraw.
  function testDepositAndWithdrawRoundingFuzz(uint amount) external {
    uint fuzzHighRange = 200 ether;
    vm.assume(amount > 0 && amount < fuzzHighRange);
    console.log("Amount",  amount);

    address depositor = vm.addr(1);
    uint originalVaultBal = vault.totalAssets();
    console.log("OriginalVaultBal:", originalVaultBal);

    vm.prank(impersonated);
    asset.transfer(depositor, fuzzHighRange);
    vm.stopPrank();

    vm.prank(depositor);
    asset.approve(address(vault), amount);
    vm.prank(depositor);
    vault.deposit(amount, depositor);
    uint depositorLpAmtPostDeposit = asset.balanceOf(depositor);
    vm.prank(depositor);
    asset.transfer(impersonated, depositorLpAmtPostDeposit); //clears remaining LP in depositor's wallet for later assertion

    uint shares = vault.convertToShares(amount);
    vm.prank(depositor);
    vault.withdraw(shares, depositor, depositor);

    uint withdrawnLpBal = asset.balanceOf(depositor);
    uint vaultBalanceAfterWithdraw = vault.totalAssets();
    console.log("LP pre deposit: ", amount, "LP after withdraw: ", withdrawnLpBal);
    console.log("Vault Balance after withdrawal:", vaultBalanceAfterWithdraw);

    assertEq(originalVaultBal, vaultBalanceAfterWithdraw, "Vault balance should be the same after deposit and withdraw");
    assertEq(amount, withdrawnLpBal, "LP amount should be the same as pre-deposit after withdrawing");
    console.log("No rounding loss between depositing and withdrawing LP.");
  }

  //Tests if vault is accruing rewards to be harvested. Returns callFee for harvest caller.
  function testCallReward() external{
    uint64 futureStamp = vault.lastHarvest() + 1000;
    vm.warp(futureStamp);
    uint reward = vault.callReward();
    console.log("Reward amt: ", reward);
    assertTrue(reward > 0, "CallReward should be > 0 after depositing as rewards accrue");
    console.log("Call reward > 0 post deposit");

  }
  //Tests if rewardBalance is accruing rewards
  function testRewardBalance() public {
    uint64 futureStamp = vault.lastHarvest() + 1000;
    vm.warp(futureStamp);
    uint rewardBal = vault.rewardBalance();

    console.log("rewardBal amount: ", rewardBal);
    assertTrue(rewardBal > 0, "rewardBal should be > 0 after depositing as rewards accrue");
    console.log("rewardBal > 0 post deposit");
  }

  //Tests Panic function which emergency withdraws funds from farm into the vault and pauses deposits.
  function testEmergencyWithdraw() external {
    console.log("Assets in farm before Panic:", vault.balanceOfPool());
    vm.prank(strategist);
    vault.panic();
    console.log("Assets in farm after Panic:", vault.balanceOfPool());
    console.log("Assets rescued into the vault:", vault.idleFunds());

    assertTrue(vault.balanceOfPool() == 0, "Vaulted farm should have 0 LP deposited");
    assertTrue(vault.idleFunds() == lpAmount, "Funds are sitting in the vault post Emergency withdraw");
    assertTrue(vault.paused() == 1, "Vault is paused");
    console.log("Vault paused and funds emergency wthdrawn from farm.");

  }

  //Tests calls that can only be made by Owner (multisig)
  function testOnlyOwner() public {
    address oldRouter = router;
    address oldGauge = vault.gauge();
    address newGauge = 0xDFAA88D5d068370689b082D34d7B546CbF393bA9;
    vm.prank(multisig);
    vault.setRouterSetGauge(oldRouter, newGauge);
    console.log("Multisig call successful and gauge changed to:", vault.gauge());

    assertTrue(vault.gauge() != oldGauge || vault.router() != oldRouter, "Router or Gauge Changed");

    vm.prank(unauthorized);
    try
    vault.setRouterSetGauge(gauge, router){}
    catch {
      assertTrue(oldRouter == vault.router() && vault.gauge() == newGauge);
      console.log("Unauthorized caller has reverted");
    }
  }

  //Tests the rescue of a token mistakenly sent to the vault.
  function testStuckTokens() public {
    uint tokenAmt = 10000000000000000000;
    vm.prank(stuckTokenOwner);
    unrelatedToken.transfer(address(vault), tokenAmt);
    vm.stopPrank();

    uint unrelatedVaultBalance = unrelatedToken.balanceOf(address(vault));
    vm.prank(strategist);
    vault.stuckTokens(address(unrelatedToken), 0);
    uint unrelatedVaultBalanceAfterStuck = unrelatedToken.balanceOf(address(vault));
    uint strategistUnrelatedBal = unrelatedToken.balanceOf(strategist);

    assertTrue(unrelatedVaultBalanceAfterStuck == 0 && strategistUnrelatedBal == tokenAmt);
    console.log("UnrelatedBal after accidental send:", unrelatedVaultBalance,  "Bal after calling stuckTokens():", unrelatedVaultBalanceAfterStuck);
    console.log("Strategist Unrelated Bal after call", strategistUnrelatedBal);
    console.log("Stuck token successfully retrieved");

  }

  // Tests if customTx successfully converts target token to more reward
  function testCustomTX() public {
    uint tokenAmt = 10 ether;
    vm.prank(stuckTokenOwner);
    unrelatedToken.transfer(address(vault), tokenAmt);
    vm.stopPrank();

    // Approve the vault to spend the unrelatedToken
    unrelatedToken.approve(address(vault), tokenAmt);

    // Define the swap path
    IEqualizerRouter.Routes[] memory path = new IEqualizerRouter.Routes[](2);
    path[0] = IEqualizerRouter.Routes(address(unrelatedToken), address(wftm), false);
    path[1] = IEqualizerRouter.Routes(address(wftm), address(equal), false);

    uint unrelatedBalPreSwap = unrelatedToken.balanceOf(address(vault));
    console.log("Vault UnrelatedBal pre swap = ", unrelatedBalPreSwap);

    // Call customTx to swap unrelatedToken for equal
    vm.prank(multisig);
    vault.customTx(address(unrelatedToken), 0, path);


    // Check that the unrelatedToken balance is zero and equal balance has increased
    uint unrelatedTokenVaultBalance = unrelatedToken.balanceOf(address(vault));
    console.log("Vault UnrelatedBal post swap: ", unrelatedTokenVaultBalance);
    assertTrue(unrelatedTokenVaultBalance == 0, "Vault should have no unrelatedToken after swap");
    console.log("Vault has 0 unrelatedTokenBal post swap, increasing rewardTokenBal");
  }

  function testPauseUnpause() public {
    vm.prank(strategist);
    console.log("Paused state pre-call:", vault.paused());
    vm.prank(strategist);
    vault.pause();
    console.log("Paused state post-call:", vault.paused());
    vm.prank(strategist);
    vault.unpause();
    console.log("Paused state post unpause", vault.paused());

    assertTrue(vault.paused() != 1);
    console.log("Pause and unpause procedure performed as expected");
  }

  function testDeniedUnauthorizedWithdraw() external {
    address attacker = strategist;

    uint shares = vault.convertToShares(lpAmount);
    uint vaultBalanceBefore = vault.totalAssets();

    try
    vault.withdraw(shares, attacker, legitDepositor){}
    catch {

    uint vaultBalanceAfter = vault.totalAssets();
    console.log("Total Assets Before Withdraw Attempt:", vaultBalanceBefore, "After attempt:", vaultBalanceAfter);
    assertEq(vaultBalanceAfter, vaultBalanceBefore, "Vault balance should remain unchanged after failed withdrawal");
    console.log("Attempt by attacker to withdraw depositor's funds has reverted");
    }

  }

  //Change fee value to test pass/fail.
  function testMaxPerformanceFee(uint64 fee) external {
    vm.assume(fee >= 0 && fee <=10);
    vm.prank(strategist);
    console.log("withdrawFee function call arg: ", fee);
    try
    vault.setFeesAndRecipient(fee, 120, 600, 280, 0, address(0)){}
    catch{

    uint64 withdrawFee = vault.withdrawFee();
    uint64 callFee = vault.callFee();
    uint64 treasuryFee = vault.treasuryFee();
    uint64 recipientFee = vault.recipientFee();
    uint64 stratFee = vault.stratFee();

    uint64 sum = callFee + treasuryFee + recipientFee + stratFee;
    console.log("withdrawFee after call:", vault.withdrawFee());
    assertTrue(withdrawFee == 0 || withdrawFee == 1, "Value is 0 or 0.1%");
    assertTrue(sum <= 1000, "Value adds up correctly");
    if(fee > 1){
      console.log("withdrawFee cannot be > 0.1% and call has reverted");
    } else {console.log("withdrawFee was set between bounds");}
    }

  }

  function testContractHarvesting() external {
    uint vaultBeforeBalance = vault.totalAssets();
    uint64 futureStamp = vault.lastHarvest() + 1000;
    vm.warp(futureStamp);
    try
    vault.harvest(){}
    catch {

    uint vaultBalanceAfter = vault.totalAssets();
    console.log("Before Harvest", vaultBeforeBalance, " After Harvest:", vaultBalanceAfter);
    assertTrue(vaultBalanceAfter == vaultBeforeBalance, "Total Assets in vault remain the same as it has reverted");
    console.log("Contract failed to call harvest as intended.");
    }
  }

  function testUnauthorizedAdmin() public {
    console.log("Paused state:", vault.paused());
    try 
    vault.pause() {
    } catch {
    console.log("Paused after unauthorized caller:", vault.paused());
    assertTrue(vault.paused() != 1);
    console.log("Call to admin function by unauthorized address has reverted");
    }

  }

  function testDoubleDeposit() external {
    uint vaultBeforeBal = vault.totalAssets();
    console.log("Assets in vault before 2nd deposit", vaultBeforeBal);
    try
    vault.deposit(lpAmount, legitDepositor){}
    catch {
    uint vaultAfterBal = vault.totalAssets();
    console.log("Assets in vault after 2nd deposit attempt", vaultAfterBal);
    assertTrue(vaultBeforeBal == vaultAfterBal);
    console.log("Attempt to re-deposit before time buffer has passed reverted");
    }
  }

  function testSetTimestampSource() public {
    address stampSource = 0x77CfeE25570b291b0882F68Bac770Abf512c2b5C;
    address currentSource = vault.timestampSource();
    vm.prank(strategist);
    vault.setTimestampSource(stampSource);
    assertTrue(stampSource != currentSource);
    console.log("timeStampSource changed to", stampSource);
  }

  //Tests correct functionality of setSlippageSetDelay. must set slippage to public in contract.
  function testSlippageAndDelay() public {
    vm.prank(strategist);
    try
    vault.setSlippageSetDelay(10, 800){}
    catch {
      assertTrue(vault.slippage() == 2);
      console.log("slippage value after failed call", vault.slippage());

      vm.prank(strategist);
      vault.setSlippageSetDelay(4, 800);
      console.log("slippage value after successful call", vault.slippage());

      assertTrue(vault.slippage() == 4);
      console.log("If arg called outside of bounds, reverts. If  args called within bounds, assigned to global if != to arg");
    }
  }

  function testHarvestOnDeposit(uint64 delay) public{
    vm.assume(delay > 200 && delay < 2500);
    address newDepositor = vm.addr(1);
    vm.prank(strategist);
    vault.setHarvestOnDeposit(1);
    vm.prank(impersonated);
    asset.transfer(newDepositor, lpAmount);
    uint64 lastHarvest = vault.lastHarvest();

    uint earlyVaultBalance = vault.totalAssets();
    console.log("vaultBalance:", earlyVaultBalance);
    vm.warp(lastHarvest + delay);
    IEqualizerRouter(router).swapExactTokensForTokensSimple(lpAmount, 1, equal, wftm, false, address(this), block.timestamp); //creates timestamp source after warp

    vm.prank(newDepositor);
    asset.approve(address(vault), type(uint).max);
    vm.prank(newDepositor);
    vault.deposit(lpAmount, newDepositor);

    uint laterVaultBalance = vault.totalAssets();
    console.log("VaultBalance post harvestOnDeposit:", laterVaultBalance);
    uint harvestedAmt = laterVaultBalance - (earlyVaultBalance * 2);

    console.log("Harvested amount", harvestedAmt);

    if(harvestedAmt != 0){
    assertTrue(laterVaultBalance - lpAmount * 2 != 0);
    console.log("Vault has harvested successfully with harvestOnDeposit turned on");
    } else{
      assertTrue(laterVaultBalance - (lpAmount *2) == 0);
      console.log("Vault has deposited but not harvested due to being < buffer");
    }
  }

  //Tests for correct strategist access control
  function testSetStrategist() external{
    vm.prank(strategist);
    vault.setStrategist(address(this));
    assertTrue(vault.strategist() == address(this));
    console.log("Strategist caller successfully changed strategist address to:", address(this));

    vm.prank(strategist);
    try
    vault.setStrategist(strategist){}
    catch {
      assertTrue(vault.strategist() == address(this));
      console.log("Unauthorized called reverted, strategist address remains unaltered", vault.strategist());
    }
  }
  //Tests for correct access control for onlyAdmin
   function testSetHarvester() external{
    vm.prank(strategist);
    vault.setHarvester(address(this));
    assertTrue(vault.harvester() == address(this));
    console.log("SetHarvester authorized caller successfully changed address to:", vault.harvester());
    
    vm.prank(strategist);
    try
    vault.setHarvester(strategist){}
    catch {
      assertTrue(vault.strategist() == address(this));
      console.log("Unauthorized called reverted, harvester address remains unaltered", vault.harvester());
    }
  }

  //Tests post deposit view functions that would have value & have not been tested above)
  function testViewFunctions() external {
    uint balOfPool = vault.balanceOfPool();
    uint idle = vault.idleFunds();
    uint pricePerShare = vault.getPricePerFullShare();

    assertTrue(balOfPool != 0 && idle == 0 && pricePerShare != 0 && vault.slippage() == 2 && vault.delay() == 600);
    console.log("balanceOfPool, idleFunds, getPricePerFullShare & getSlippageGetDelay are returning correct values");
  }

  function testUnauthorisedShareTransfer() external {
    uint shareBalPreAttack = vault.balanceOf(address(this));
    vm.prank(unauthorized);
    try
    vault.transferFrom(address(this), unauthorized, shareBalPreAttack){}
    catch {
    uint shareBalAfterAttack = vault.balanceOf(address(this));
    assertTrue(shareBalPreAttack == shareBalAfterAttack);
    console.log("Unauthorized shares transfer reveted");
    }
  }
}