# XpandrUnityVault

SPDX-License-Identifier: No License (None)
No permissions granted before June 1st 2026, then GPL-3.0 after this date.

@title  - XpandrUnityVault
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract.
          Includes: 0% withdraw fee default / Vault profit in USD / Deposit & harvest buffers / Timestamp & Slippage protection

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


# Test Results - Foundry

Running 21 tests for test/XpandrUnityVault.t.sol:XpandrUnityVaultTest
[PASS] testCallReward() (gas: 129090)
Logs:
  Reward amt:  1952628208512
  Call reward > 0 post deposit

[PASS] testContractHarvesting() (gas: 32703)
Logs:
  Before Harvest 2318483958593833989  After Harvest: 2318483958593833989
  Contract failed to call harvest as intended.

[PASS] testCustomTX() (gas: 459933)
Logs:
  Vault UnrelatedBal pre swap =  10000000000000000000
  Vault UnrelatedBal post swap:  0
  Vault has 0 unrelatedTokenBal post swap, increasing rewardTokenBal

[PASS] testDeniedUnauthorizedWithdraw() (gas: 38564)
Logs:
  Total Assets Before Withdraw Attempt: 2318483958593833989 After attempt: 2318483958593833989
  Attempt by attacker to withdraw depositor's funds has reverted

[PASS] testDepositAndWithdrawRoundingFuzz(uint256) (runs: 256, μ: 314802, ~: 314803) (gas: 139630)
Logs:
  LP pre deposit:  2318483958593833989 LP after withdraw:  2318483958593833989
  Vault Balance after withdrawal: 0
  No rounding loss between depositing and withdrawing LP.

[PASS] testDoubleDeposit() (gas: 46036)
Logs:
  Assets in vault before 2nd deposit 2318483958593833989
  Assets in vault after 2nd deposit attempt 2318483958593833989
  Attempt to re-deposit before time buffer has passed reverted

[PASS] testEmergencyWithdraw() (gas: 160264)
Logs:
  Assets in farm before Panic: 2318483958593833989
  Assets in farm after Panic: 0
  Assets rescued into the vault: 2318483958593833989
  Vault paused and funds emergency wthdrawn from farm.

[PASS] testHarvestOnDeposit(uint64) (runs: 256, μ: 1027821, ~: 1001464) (gas: 920931)
Logs:
  vaultBalance: 2318483958593833989
  VaultBalance post harvestOnDeposit: 4639495608025638114
  2527690837970136
  Vault has harvested successfully with harvestOnDeposit turned on

[PASS] testMaxPerformanceFee(uint64) (runs: 256, μ: 35052, ~: 31843) (gas: 30897)
Logs:
  withdrawFee function call arg:  2
  withdrawFee after call: 0
  withdrawFee cannot be > 0.1% and call has reverted

[PASS] testOnlyOwner() (gas: 26319)
Logs:
  Multisig call successful and gauge changed to: 0xDFAA88D5d068370689b082D34d7B546CbF393bA9

[PASS] testPauseUnpause() (gas: 88784)
Logs:
  Paused state pre-call: 0
  Paused state post-call: 1
  Paused state post unpause 0
  Pause and unpause procedure performed as expected

[PASS] testRewardBalance() (gas: 40554)
Logs:
  rewardBal amount:  54840367450933
  rewardBal > 0 post deposit

[PASS] testSetTimestampSource() (gas: 24444)
Logs:
  timeStampSource changed to 0x77CfeE25570b291b0882F68Bac770Abf512c2b5C

[PASS] testSlippageAndDelay() (gas: 37071)
Logs:
  slippage value after failed call 2
  slippage value after successful call 4
  If arg called outside of bounds, reverts. If  args called within bounds, assigned to global if != to arg

[PASS] testStuckTokens() (gas: 70312)
Logs:
  UnrelatedBal after accidental send: 10000000000000000000 Bal after calling stuckTokens(): 0
  Strategist Unrelated Bal after call 10000000000000000000
  Stuck token successfully retrieved

[PASS] testUnauthorizedAdmin() (gas: 19575)
Logs:
  Paused state: 0
  Paused after unauthorized caller: 0
  Call to admin function by unauthorized address has reverted

[PASS] testadminHarvesting() (gas: 638349)
Logs:
  Before Harvest: 2318483958593833989  After Harvest: 2318509235502213689
  Harvest successful and totalAssets() increased

[PASS] testViewFunctions() (gas: 32162)
Logs:
  balanceOfPool, idleFunds, getPricePerFullShare & getSlippageGetDelay are returning correct values

[PASS] testUnauthorisedShareTransfer() (gas: 20557)
Logs:
  Unauthorized shares transfer reverted

[PASS] testSetStrategist() (gas: 26250)
Logs:
  Strategist caller successfully changed strategist address to: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496
  Unauthorized called reverted, strategist address remains unaltered 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496

[PASS] testSetHarvester() (gas: 30450)
Logs:
  SetHarvester authorized caller successfully changed address to: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496


Test result: ok. 21 passed; 0 failed; 0 skipped; finished in 26.34s
 
Ran 1 test suites: 21 tests passed, 0 failed, 0 skipped (21 total tests)


# Coverage excluding libs/interfaces
| File                                         | % Lines          | % Statements     | % Branches      | % Funcs        |
|----------------------------------------------|------------------|------------------|-----------------|----------------|
| src/XpandrUnityVault.sol                     | 90.78% (128/141) | 84.27% (209/248) | 62.50% (45/72)  | 86.11% (31/36) |
| src/interfaces/AccessControl.sol             | 80.00% (8/10)    | 80.00% (16/20)   | 87.50% (7/8)    | 83.33% (5/6)   |
| src/interfaces/Pauser.sol                    | 100.00% (7/7)    | 81.82% (9/11)    | 50.00% (2/4)    | 100.00% (5/5)  |
| Total                                        | 90.50% (143/158) | 83.87% (234/279) | 64.28% (54/84)  | 87.23% (41/47) |

87.2% avg coverage excl/ branches.
