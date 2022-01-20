// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;

import {IKlaybankDistributionManager} from '../interfaces/IKlaybankDistributionManager.sol';
import {SafeMath} from '../lib/SafeMath.sol';
import {PercentageMath} from '../lib/PercentageMath.sol';
import {DistributionTypes} from '../lib/DistributionTypes.sol';

contract KlaybankDistributionManager is IKlaybankDistributionManager {
  using SafeMath for uint256;
  using PercentageMath for uint256;

  struct AssetData {
    uint256 index;
    uint16 shareRatio;
    uint256 lastUpdateTimestamp;
    uint256 distributionStartTimestamp;
    mapping(address => uint256) users;
    uint256[] monthlyEmissionPerSecond;
  }

  struct IndexLocalVar {
    uint256 currentTimestamp;
    uint256 targetDistributionTime;
    uint256 distributedTime;
    uint256 currentMonthIndex;
    uint256 emissionDelta;
    uint256 currentMonthTimeDelta;
    uint256 currentMonthTimestamp;
    uint256 unsettledMonths;
    uint256 unsettledTimeDelta;
  }

  uint256 public constant SECONDS_OF_ONE_MONTH = 30 * 24 * 60 * 60;

  uint256 public constant PERCENTAGE_FACTOR = 1e4;

  address public immutable EMISSION_MANAGER;

  uint8 public constant PRECISION = 18;

  mapping(address => AssetData) public assets;

  modifier onlyEmissionManager() {
    require(msg.sender == EMISSION_MANAGER, 'ONLY_EMISSION_MANAGER');
    _;
  }

  constructor(address emissionManager) {
    EMISSION_MANAGER = emissionManager;
  }

  function setDistributionStartTimestamp(address asset, uint256 distributionStartTimestamp) external override onlyEmissionManager {
    require(distributionStartTimestamp > block.timestamp, 'INVALID_DISTRIBUTION_START');
    assets[asset].distributionStartTimestamp = distributionStartTimestamp;
    emit DistributionStartUpdated(distributionStartTimestamp);
  }

  function getDistributionEndTimestamp(address asset) external view override returns (uint256) {
    return _getDistributionEndTimestamp(asset);
  }

  function _getDistributionEndTimestamp(address asset) internal view returns (uint256) {
    AssetData storage assetData = assets[asset];
    return assetData.distributionStartTimestamp.add(
      assetData.monthlyEmissionPerSecond.length.mul(SECONDS_OF_ONE_MONTH)
    );
  }

  function getDistributionStartTimestamp(address asset) external view override returns (uint256) {
    return assets[asset].distributionStartTimestamp;
  }

  function getUserAssetData(address user, address asset) public view override returns (uint256) {
    return assets[asset].users[user];
  }

  function getAssetData(address asset) public view override returns (uint256, uint256[] memory, uint16, uint256, uint256) {
    return (
    assets[asset].index,
    assets[asset].monthlyEmissionPerSecond,
    assets[asset].shareRatio,
    assets[asset].lastUpdateTimestamp,
    assets[asset].distributionStartTimestamp
    );
  }

  /**
   * @dev Configure the assets for a specific emission
   * @param assetsConfigInput The array of each asset configuration
   **/
  function _configureAssets(DistributionTypes.AssetConfigInput[] memory assetsConfigInput)
  internal
  {
    for (uint256 i = 0; i < assetsConfigInput.length; i++) {
      AssetData storage assetConfig = assets[assetsConfigInput[i].underlyingAsset];
      require(assetConfig.shareRatio <= PERCENTAGE_FACTOR, 'INVALID_SHARE_RATIO');

      _updateAssetStateInternal(
        assetsConfigInput[i].underlyingAsset,
        assetConfig,
        assetsConfigInput[i].totalStaked
      );

      assetConfig.monthlyEmissionPerSecond = assetsConfigInput[i].monthlyEmissionPerSecond;
      assetConfig.shareRatio = assetsConfigInput[i].shareRatio;
      emit AssetConfigUpdated(
        assetsConfigInput[i].underlyingAsset,
        assetsConfigInput[i].monthlyEmissionPerSecond,
        assetsConfigInput[i].shareRatio
      );
    }
  }

  /**
   * @dev Updates the state of one distribution, mainly rewards index and timestamp
   * @param asset The address of the asset being updated
   * @param assetConfig Storage pointer to the distribution's config
   * @param totalStaked Current total of staked assets for this distribution
   * @return The new distribution index
   **/
  function _updateAssetStateInternal(
    address asset,
    AssetData storage assetConfig,
    uint256 totalStaked
  ) internal returns (uint256) {
    uint256 oldIndex = assetConfig.index;
    uint256[] memory monthlyEmissionPerSecond = assetConfig.monthlyEmissionPerSecond;
    uint16 shareRatio = assetConfig.shareRatio;
    uint256 lastUpdateTimestamp = assetConfig.lastUpdateTimestamp;
    uint256 distributionStartTimestamp = assetConfig.distributionStartTimestamp;

    if (block.timestamp == lastUpdateTimestamp) {
      return oldIndex;
    }

    uint256 newIndex =
    _getAssetIndex(oldIndex, shareRatio, monthlyEmissionPerSecond, lastUpdateTimestamp, distributionStartTimestamp, totalStaked);
    if (newIndex != oldIndex) {
      //optimization: storing one after another saves one SSTORE
      assetConfig.index = newIndex;
      emit AssetIndexUpdated(asset, newIndex);
    } else {
    }
    assetConfig.lastUpdateTimestamp = uint40(block.timestamp);
    return newIndex;
  }

  /**
   * @dev Updates the state of an user in a distribution
   * @param user The user's address
   * @param asset The address of the reference asset of the distribution
   * @param stakedByUser Amount of tokens staked by the user in the distribution at the moment
   * @param totalStaked Total tokens staked in the distribution
   * @return The accrued rewards for the user until the moment
   **/
  function _updateUserAssetInternal(
    address user,
    address asset,
    uint256 stakedByUser,
    uint256 totalStaked
  ) internal returns (uint256) {
    AssetData storage assetData = assets[asset];
    uint256 userIndex = assetData.users[user];
    uint256 accruedRewards = 0;

    uint256 newIndex = _updateAssetStateInternal(asset, assetData, totalStaked);
    if (userIndex != newIndex) {
      if (stakedByUser != 0) {
        accruedRewards = _getRewards(stakedByUser, newIndex, userIndex);
      }

      assetData.users[user] = newIndex;
      emit UserIndexUpdated(user, asset, newIndex);
    }

    return accruedRewards;
  }

  /**
 * @dev Used by "frontend" stake contracts to update the data of an user when claiming rewards from there
 * @param user The address of the user
 * @param stakes List of structs of the user data related with his stake
 * @return The accrued rewards for the user until the moment
 **/
  function _claimRewards(address user, DistributionTypes.UserStakeInput[] memory stakes)
  internal
  returns (uint256)
  {
    uint256 accruedRewards = 0;

    for (uint256 i = 0; i < stakes.length; i++) {
      accruedRewards = accruedRewards.add(
        _updateUserAssetInternal(
          user,
          stakes[i].underlyingAsset,
          stakes[i].stakedByUser,
          stakes[i].totalStaked
        )
      );
    }

    return accruedRewards;
  }

  /**
   * @dev Return the accrued rewards for an user over a list of distribution
   * @param user The address of the user
   * @param stakes List of structs of the user data related with his stake
   * @return The accrued rewards for the user until the moment
   **/
  function _getUnclaimedRewards(address user, DistributionTypes.UserStakeInput[] memory stakes)
  internal
  view
  returns (uint256)
  {
    uint256 accruedRewards = 0;

    for (uint256 i = 0; i < stakes.length; i++) {
      AssetData storage assetConfig = assets[stakes[i].underlyingAsset];
      uint256 assetIndex =
      _getAssetIndex(
        assetConfig.index,
        assetConfig.shareRatio,
        assetConfig.monthlyEmissionPerSecond,
        assetConfig.lastUpdateTimestamp,
        assetConfig.distributionStartTimestamp,
        stakes[i].totalStaked
      );

      accruedRewards = accruedRewards.add(
        _getRewards(stakes[i].stakedByUser, assetIndex, assetConfig.users[user])
      );
    }
    return accruedRewards;
  }

  /**
   * @dev Internal function for the calculation of user's rewards on a distribution
   * @param principalUserBalance Amount staked by the user on a distribution
   * @param reserveIndex Current index of the distribution
   * @param userIndex Index stored for the user, representation his staking moment
   * @return The rewards
   **/
  function _getRewards(
    uint256 principalUserBalance,
    uint256 reserveIndex,
    uint256 userIndex
  ) internal pure returns (uint256) {
    return principalUserBalance.mul(reserveIndex.sub(userIndex)) / 10 ** uint256(PRECISION);
  }

  /**
   * @dev Calculates the next value of an specific distribution index, with validations
   * @param currentIndex Current index of the distribution
   * @param monthlyEmissionPerSecond Representing the total rewards distributed per second per month, on the distribution
   * @param lastUpdateTimestamp Last moment this distribution was updated
   * @param totalBalance of tokens considered for the distribution
   * @return The new index.
   **/
  function _getAssetIndex(
    uint256 currentIndex,
    uint16 shareRatio,
    uint256[] memory monthlyEmissionPerSecond,
    uint256 lastUpdateTimestamp,
    uint256 distributionStartTimestamp,
    uint256 totalBalance
  ) internal view returns (uint256) {
    uint256 distributionEndTimestamp = distributionStartTimestamp.add(
      monthlyEmissionPerSecond.length.mul(SECONDS_OF_ONE_MONTH)
    );

    if (
      monthlyEmissionPerSecond.length == 0 ||
      totalBalance == 0 ||
      distributionStartTimestamp == 0 ||
      distributionStartTimestamp > block.timestamp ||
      lastUpdateTimestamp == block.timestamp ||
      lastUpdateTimestamp >= distributionEndTimestamp
    ) {
      return currentIndex;
    }

    IndexLocalVar memory vars;
    vars.currentTimestamp = block.timestamp > distributionEndTimestamp ? distributionEndTimestamp : block.timestamp;
    vars.distributedTime = vars.currentTimestamp.sub(distributionStartTimestamp);
    if (vars.currentTimestamp == distributionEndTimestamp) {
      vars.currentMonthIndex = monthlyEmissionPerSecond.length - 1;
      vars.currentMonthTimeDelta = SECONDS_OF_ONE_MONTH;
      vars.currentMonthTimestamp = vars.currentTimestamp.sub(
        SECONDS_OF_ONE_MONTH
      );
    } else {
      vars.currentMonthIndex = vars.distributedTime.div(SECONDS_OF_ONE_MONTH);
      vars.currentMonthTimeDelta = vars.distributedTime.mod(SECONDS_OF_ONE_MONTH);
      vars.currentMonthTimestamp = vars.currentTimestamp.sub(
        vars.currentMonthTimeDelta
      );
    }

    // in same month
    if (lastUpdateTimestamp >= vars.currentMonthTimestamp) {
      vars.emissionDelta = monthlyEmissionPerSecond[vars.currentMonthIndex].mul(
        vars.currentTimestamp.sub(lastUpdateTimestamp)
      );
      return vars.emissionDelta
        .mul(10 ** uint256(PRECISION))
        .percentMul(shareRatio)
        .div(totalBalance)
        .add(currentIndex);
    }

    vars.emissionDelta = monthlyEmissionPerSecond[vars.currentMonthIndex].mul(vars.currentMonthTimeDelta);
    vars.unsettledMonths = vars.currentMonthTimestamp.sub(lastUpdateTimestamp).div(SECONDS_OF_ONE_MONTH);
    vars.unsettledTimeDelta = vars.currentMonthTimestamp.sub(lastUpdateTimestamp).mod(SECONDS_OF_ONE_MONTH);

    // 0 <= unsettledMonths <= currentMonth, when lastUpdateTimestamp and distributionStartTimestamp is same, unsettledMonths and currentMonth is same
    for (uint256 i = vars.currentMonthIndex - 1; i >= (vars.currentMonthIndex - vars.unsettledMonths) && i < monthlyEmissionPerSecond.length; i--) {
      vars.emissionDelta = vars.emissionDelta.add(monthlyEmissionPerSecond[i].mul(SECONDS_OF_ONE_MONTH));
    }

    // when lastUpdateTimestamp and distributionStartTimestamp is same, unsettledMonths and currentMonth is same
    if (vars.currentMonthIndex != vars.unsettledMonths) {
      vars.emissionDelta = vars.emissionDelta.add(
        monthlyEmissionPerSecond[vars.currentMonthIndex - vars.unsettledMonths - 1]
        .mul(vars.unsettledTimeDelta)
      );
    }

    return vars.emissionDelta
      .mul(10 ** uint256(PRECISION))
      .percentMul(shareRatio)
      .div(totalBalance)
      .add(currentIndex);
  }
}
