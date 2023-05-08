// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

contract XpandrErrors {
    error ZeroAmount();
    error NotVault();
    error NotEOA();
    error NoAuth();
    error NotAccountOwner();
    error InvalidProposal();
    error OverMaxFee();
    error OverFeeDiv();
    error NoShares();
    error OverBalance();
    error ZeroAddress();
    error UnderTimeLock();
    error InvalidToken();
}