//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./solmate/ERC20.sol";

interface IStrategy { 
    function vault() external view returns (address);
    function deposit() external;
    function afterDeposit() external;
    function withdraw(uint) external;
    function balanceOf() external view returns (uint);
    function harvest() external;
    function removeStrat() external;
    function panic() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (uint8);
    function harvestOnDeposit() external view returns(uint);
    function harvestProfits() external view returns(uint64);
    function getDelay() external view returns(uint64);
}

