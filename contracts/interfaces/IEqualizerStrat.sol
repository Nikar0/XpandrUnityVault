//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./solmate/ERC20.sol";

interface IEqualizerStrat { 
    function vault() external view returns (address);
    function want() external view returns (ERC20);
    function beforeDeposit() external;
    function deposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
    function harvest() external;
    function retireStrat() external;
    function panic() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

