// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.19;

contract XpandrErrors {
    error ZeroAmount();
    error ZeroAddress();
    error NotVault();
    error NotEOA();
    error NotAccountOwner();
    error OverCap();
    error UnderTimeLock();
    error InvalidProposal();
    error InvalidTokenOrPath();
}
