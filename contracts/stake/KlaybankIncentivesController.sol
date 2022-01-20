// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;

import {SafeKIP7} from '../lib/SafeKIP7.sol';
import {SafeMath} from '../lib/SafeMath.sol';
import {DistributionTypes} from '../lib/DistributionTypes.sol';
import {VersionedInitializable} from '../utils/VersionedInitializable.sol';
import {KlaybankDistributionManager} from './KlaybankDistributionManager.sol';
import {IStakedTokenWithConfig} from '../interfaces/IStakedTokenWithConfig.sol';
import {IKIP7} from '../interfaces/IKIP7.sol';
import {IScaledBalanceToken} from '../interfaces/IScaledBalanceToken.sol';
import {IKlaybankIncentivesController} from '../interfaces/IKlaybankIncentivesController.sol';

/**
 * @title StakedTokenIncentivesController
 * @notice Distributor contract for rewards to the Kbt protocol, using a staked token as rewards asset.
 * The contract stakes the rewards before redistributing them to the Kbt protocol participants.
 * @author Aave
 **/
contract KlaybankIncentivesController is
  IKlaybankIncentivesController,
  VersionedInitializable,
  KlaybankDistributionManager
{
  using SafeMath for uint256;
  using SafeKIP7 for IKIP7;

  uint256 public constant REVISION = 1;

  IStakedTokenWithConfig public immutable STAKED_TOKEN;

  mapping(address => uint256) internal _usersUnclaimedRewards;

  // this mapping allows whitelisted addresses to claim on behalf of others
  // useful for contracts that hold tokens to be rewarded but don't have any native logic to claim Liquidity Mining rewards
  mapping(address => address) internal _authorizedClaimers;

  modifier onlyAuthorizedClaimers(address claimer, address user) {
    require(_authorizedClaimers[user] == claimer, 'CLAIMER_UNAUTHORIZED');
    _;
  }

  constructor(
    IStakedTokenWithConfig stakedToken,
    address emissionManager
  )
    KlaybankDistributionManager(emissionManager)
  {
    STAKED_TOKEN = stakedToken;
  }

  function initialize() external initializer {
    IKIP7(STAKED_TOKEN.GOVERNANCE_TOKEN()).safeApprove(address(STAKED_TOKEN), type(uint256).max);
  }

  function configureAssets(address[] calldata assets, uint256[][] calldata assetMonthlyEmissionPerSecond, uint16[] calldata shareRatios)
    external
    override
    onlyEmissionManager
  {
    require(assets.length == assetMonthlyEmissionPerSecond.length && assets.length == shareRatios.length, 'INVALID_CONFIGURATION');

    DistributionTypes.AssetConfigInput[] memory assetsConfig =
      new DistributionTypes.AssetConfigInput[](assets.length);

    for (uint256 i = 0; i < assets.length; i++) {
      assetsConfig[i].underlyingAsset = assets[i];
      assetsConfig[i].monthlyEmissionPerSecond = assetMonthlyEmissionPerSecond[i];
      assetsConfig[i].shareRatio = shareRatios[i];
      assetsConfig[i].totalStaked = IScaledBalanceToken(assets[i]).scaledTotalSupply();
    }
    _configureAssets(assetsConfig);
  }

  function handleAction(
    address user,
    uint256 totalSupply,
    uint256 userBalance
  ) external override {
    uint256 accruedRewards = _updateUserAssetInternal(user, msg.sender, userBalance, totalSupply);
    if (accruedRewards != 0) {
      _usersUnclaimedRewards[user] = _usersUnclaimedRewards[user].add(accruedRewards);
      emit RewardsAccrued(user, accruedRewards);
    }
  }

  function getRewardsBalance(address[] calldata assets, address user)
    external
    view
    override
    returns (uint256)
  {
    uint256 unclaimedRewards = _usersUnclaimedRewards[user];

    DistributionTypes.UserStakeInput[] memory userState =
      new DistributionTypes.UserStakeInput[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      userState[i].underlyingAsset = assets[i];
      (userState[i].stakedByUser, userState[i].totalStaked) = IScaledBalanceToken(assets[i])
        .getScaledUserBalanceAndSupply(user);
    }
    unclaimedRewards = unclaimedRewards.add(_getUnclaimedRewards(user, userState));
    return unclaimedRewards;
  }

  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to
  ) external override returns (uint256) {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, msg.sender, to);
  }

  function claimRewardsOnBehalf(
    address[] calldata assets,
    uint256 amount,
    address user,
    address to
  ) external override onlyAuthorizedClaimers(msg.sender, user) returns (uint256) {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, user, to);
  }

  function setClaimer(address user, address caller) external override onlyEmissionManager {
    _authorizedClaimers[user] = caller;
    emit ClaimerSet(user, caller);
  }

  function getClaimer(address user) external view override returns (address) {
    return _authorizedClaimers[user];
  }

  function getUserUnclaimedRewards(address _user) external view override returns (uint256) {
    return _usersUnclaimedRewards[_user];
  }

  function REWARD_TOKEN() external view override returns (address) {
    return address(STAKED_TOKEN);
  }

  /**
   * @dev returns the revision of the implementation contract
   */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  /**
   * @dev Claims reward for an user on behalf, on all the assets of the lending pool, accumulating the pending rewards.
   * @param amount Amount of rewards to claim
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @return Rewards claimed
   **/
  function _claimRewards(
    address[] calldata assets,
    uint256 amount,
    address claimer,
    address user,
    address to
  ) internal returns (uint256) {
    if (amount == 0) {
      return 0;
    }
    uint256 unclaimedRewards = _usersUnclaimedRewards[user];

    DistributionTypes.UserStakeInput[] memory userState =
      new DistributionTypes.UserStakeInput[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      userState[i].underlyingAsset = assets[i];
      (userState[i].stakedByUser, userState[i].totalStaked) = IScaledBalanceToken(assets[i])
        .getScaledUserBalanceAndSupply(user);
    }

    uint256 accruedRewards = _claimRewards(user, userState);
    if (accruedRewards != 0) {
      unclaimedRewards = unclaimedRewards.add(accruedRewards);
      emit RewardsAccrued(user, accruedRewards);
    }

    if (unclaimedRewards == 0) {
      return 0;
    }
    uint256 amountToClaim = amount > unclaimedRewards ? unclaimedRewards : amount;
    _usersUnclaimedRewards[user] = unclaimedRewards - amountToClaim; // Safe due to the previous line

    STAKED_TOKEN.stake(to, amountToClaim);
    emit RewardsClaimed(user, to, claimer, amountToClaim);

    return amountToClaim;
  }
}
