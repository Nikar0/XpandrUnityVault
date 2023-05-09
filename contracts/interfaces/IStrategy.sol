//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "./solmate/ERC20.sol";

interface IStrategy { 
    function vault() external view returns (address);
    function asset() external view returns (ERC20);
    function deposit() external;
    function afterDeposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
    function harvest() external;
    function retireStrat() external;
    function panic() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function harvestOnDeposit() external view returns(uint256);
    function profit() external view returns(uint256);
}

