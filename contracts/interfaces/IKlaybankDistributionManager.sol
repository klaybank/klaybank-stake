// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;

import {DistributionTypes} from '../lib/DistributionTypes.sol';

interface IKlaybankDistributionManager {
  event AssetConfigUpdated(address indexed asset, uint256[] monthlyEmissionPerSecond, uint16 shareRatio);
  event AssetIndexUpdated(address indexed asset, uint256 index);
  event UserIndexUpdated(address indexed user, address indexed asset, uint256 index);
  event DistributionEndUpdated(uint256 newDistributionEnd);
  event DistributionStartUpdated(uint256 newDistributionStart);

  /**
* @dev Sets the start date for the distribution
  * @param distributionStartTimestamp The end date timestamp
  **/
  function setDistributionStartTimestamp(address asset, uint256 distributionStartTimestamp) external;

  /**
  * @dev Gets the end date for the distribution
  * @return The end of the distribution
  **/
  function getDistributionEndTimestamp(address asset) external view returns (uint256);

  /**
* @dev Gets the start date for the distribution
  * @return The start of the distribution
  **/
  function getDistributionStartTimestamp(address asset) external view returns (uint256);

  /**
  * @dev Returns the data of an user on a distribution
  * @param user Address of the user
  * @param asset The address of the reference asset of the distribution
  * @return The new index
  **/
  function getUserAssetData(address user, address asset) external view returns (uint256);

  /**
  * @dev Returns the configuration of the distribution for a certain asset
  * @param asset The address of the reference asset of the distribution
  * @return The asset index, the emission per second and the last updated timestamp
  **/
  function getAssetData(address asset) external view returns (uint256, uint256[] memory, uint16, uint256, uint256);
}
