// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;

interface IStakedToken {
  function stake(address onBehalfOf, uint256 amount) external;

  function stakeAndActivateHeatup(uint256 amount) external;

  function redeem(address to, uint256 amount) external;

  function heatup() external;

  function claimRewards(address to, uint256 amount) external;
}
