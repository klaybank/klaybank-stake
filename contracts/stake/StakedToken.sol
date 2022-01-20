// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;

import {IKIP7} from '../interfaces/IKIP7.sol';
import {IStakedToken} from '../interfaces/IStakedToken.sol';
import {IStakedTokenWithConfig} from '../interfaces/IStakedTokenWithConfig.sol';
import {ITransferHook} from '../interfaces/ITransferHook.sol';

import {SafeMath} from '../lib/SafeMath.sol';
import {PercentageMath} from '../lib/PercentageMath.sol';
import {SafeKIP7} from '../lib/SafeKIP7.sol';
import {KIP7} from '../lib/KIP7.sol';
import {DistributionTypes} from '../lib/DistributionTypes.sol';

import {GovernancePowerWithSnapshot} from '../lib/GovernancePowerWithSnapshot.sol';
import {VersionedInitializable} from '../utils/VersionedInitializable.sol';
import {KlaybankDistributionManager} from './KlaybankDistributionManager.sol';

/**
 * @title StakedToken
 * @notice Contract to stake Klaybank token, tokenize the position and get rewards, inheriting from a distribution manager contract
 * @author Aave
 **/
contract StakedToken is
  IStakedToken,
  GovernancePowerWithSnapshot,
  VersionedInitializable,
  KlaybankDistributionManager
{
  using SafeMath for uint256;
  using PercentageMath for uint256;
  using SafeKIP7 for IKIP7;

  /// @dev Start of Storage layout from StakedToken v1
  uint256 public constant REVISION = 1;

  IKIP7 public immutable GOVERNANCE_TOKEN;

  address public stakedToken;
  uint16 internal _stakedTokenRewardRatio;

  uint256 public immutable HEATUP_SECONDS;

  /// @notice Seconds available to redeem once the heatup period is fullfilled
  uint256 public immutable UNSTAKE_WINDOW;

  /// @notice Address to pull from the rewards, needs to have approved this contract
  address public immutable REWARDS_VAULT;

  mapping(address => uint256) public stakerRewardsToClaim;
  mapping(address => uint256) public stakersHeatups;

  /// @dev End of Storage layout from StakedToken v1

  /// @dev To see the voting mappings, go to GovernancePowerWithSnapshot.sol
  mapping(address => address) internal _votingDelegates;

  mapping(address => mapping(uint256 => Snapshot)) internal _propositionPowerSnapshots;
  mapping(address => uint256) internal _propositionPowerSnapshotsCounts;
  mapping(address => address) internal _propositionPowerDelegates;

  bytes32 public DOMAIN_SEPARATOR;
  bytes public constant EIP712_REVISION = bytes('1');
  bytes32 internal constant EIP712_DOMAIN =
  keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
  bytes32 public constant PERMIT_TYPEHASH =
  keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  /// @dev owner => next valid nonce to submit with permit()
  mapping(address => uint256) public _nonces;

  event Staked(address indexed from, address indexed onBehalfOf, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount);

  event RewardsAccrued(address user, uint256 amount);
  event RewardsClaimed(address indexed from, address indexed to, uint256 stakedTokenAmount, uint256 governanceTokenAmount);

  event Heatup(address indexed user);
  event StakedTokenRewardRatioChanged(uint16 stakedTokenReward);

  event SetKlaybankGovernance(address klaybankGovernance);

  constructor(
    IKIP7 governanceToken,
    uint256 heatUpSeconds,
    uint256 unstakeWindow,
    address rewardsVault,
    address emissionManager,
    string memory name,
    string memory symbol,
    uint8 decimals
  ) public KIP7(name, symbol) KlaybankDistributionManager(emissionManager) {
    GOVERNANCE_TOKEN = governanceToken;
    HEATUP_SECONDS = heatUpSeconds;
    UNSTAKE_WINDOW = unstakeWindow;
    REWARDS_VAULT = rewardsVault;
    KIP7._setDecimals(decimals);
  }

  /**
   * @dev Called by the proxy contract
   **/
  function initialize(
    address klaybankGovernance,
    string calldata tokenName,
    string calldata tokenSymbol,
    uint8 tokenDecimals,
    address stakedTokenAddress,
    uint16 stakedTokenRewardRatio,
    uint256 chainId
  ) external initializer {
    require(stakedTokenRewardRatio <= PERCENTAGE_FACTOR, 'INVALID_REWARD_RATIO');

    stakedToken = stakedTokenAddress;
    _stakedTokenRewardRatio = stakedTokenRewardRatio;
    _setName(tokenName);
    _setSymbol(tokenSymbol);
    _setDecimals(tokenDecimals);
    _setKlaybankGovernance(ITransferHook(klaybankGovernance));

    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        EIP712_DOMAIN,
        keccak256(bytes(name())),
        keccak256(EIP712_REVISION),
        chainId,
        address(this)
      )
    );

    IKIP7(IStakedTokenWithConfig(stakedTokenAddress).GOVERNANCE_TOKEN()).safeApprove(stakedTokenAddress, type(uint256).max);
  }

  function configureAsset(uint256[] memory monthlyEmissionPerSecond, uint16 shareRatio) external onlyEmissionManager {
    DistributionTypes.AssetConfigInput memory stakedTokenConfigure = DistributionTypes.AssetConfigInput(
      monthlyEmissionPerSecond,
      shareRatio,
      totalSupply(),
      address(this)
    );

    DistributionTypes.AssetConfigInput[] memory assetsConfigure = new DistributionTypes.AssetConfigInput[](1);
    assetsConfigure[0] = stakedTokenConfigure;
    _configureAssets(assetsConfigure);
  }

  function stake(address onBehalfOf, uint256 amount) external override {
    _stake(msg.sender, onBehalfOf, amount);
  }

  function _stake(address from, address onBehalfOf, uint256 amount) internal {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    uint256 balanceOfUser = balanceOf(onBehalfOf);

    uint256 accruedRewards =
    _updateUserAssetInternal(onBehalfOf, address(this), balanceOfUser, totalSupply());
    if (accruedRewards != 0) {
      emit RewardsAccrued(onBehalfOf, accruedRewards);
      stakerRewardsToClaim[onBehalfOf] = stakerRewardsToClaim[onBehalfOf].add(accruedRewards);
    }

    stakersHeatups[onBehalfOf] = getNextHeatupTimestamp(0, amount, onBehalfOf, balanceOfUser);

    _mint(onBehalfOf, amount);
    IKIP7(GOVERNANCE_TOKEN).safeTransferFrom(from, address(this), amount);
    emit Staked(from, onBehalfOf, amount);
  }

  function stakeAndActivateHeatup(uint256 amount) external override {
    _stake(msg.sender, msg.sender, amount);
    _heatup(msg.sender);
  }

  /**
   * @dev Redeems staked tokens, and stop earning rewards
   * @param to Address to redeem to
   * @param amount Amount to redeem
   **/
  function redeem(address to, uint256 amount) external override {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    //solium-disable-next-line
    uint256 heatupStartTimestamp = stakersHeatups[msg.sender];
    require(
      block.timestamp > heatupStartTimestamp.add(HEATUP_SECONDS),
      'INSUFFICIENT_HEATUP'
    );
    require(
      block.timestamp.sub(heatupStartTimestamp.add(HEATUP_SECONDS)) <= UNSTAKE_WINDOW,
      'UNSTAKE_WINDOW_FINISHED'
    );
    uint256 balanceOfMessageSender = balanceOf(msg.sender);

    uint256 amountToRedeem = (amount > balanceOfMessageSender) ? balanceOfMessageSender : amount;

    _updateCurrentUnclaimedRewards(msg.sender, balanceOfMessageSender, true);

    _burn(msg.sender, amountToRedeem);

    if (balanceOfMessageSender.sub(amountToRedeem) == 0) {
      stakersHeatups[msg.sender] = 0;
    }

    IKIP7(GOVERNANCE_TOKEN).safeTransfer(to, amountToRedeem);

    emit Redeem(msg.sender, to, amountToRedeem);
  }

  /**
   * @dev Activates the heatup period to unstake
   * - It can't be called if the user is not staking
   **/
  function heatup() external override {
    require(balanceOf(msg.sender) != 0, 'INVALID_BALANCE_ON_HEATUP');
    _heatup(msg.sender);
  }

  function _heatup(address account) internal {
    //solium-disable-next-lin
    stakersHeatups[account] = block.timestamp;

    emit Heatup(account);
  }

  /**
   * @dev Claims an `amount` of `REWARD_TOKEN` to the address `to`
   * @param to Address to stake for
   * @param amount Amount to stake
   **/
  function claimRewards(address to, uint256 amount) external override {
    uint256 newTotalRewards =
    _updateCurrentUnclaimedRewards(msg.sender, balanceOf(msg.sender), false);
    uint256 amountToClaim = (amount == type(uint256).max) ? newTotalRewards : amount;

    stakerRewardsToClaim[msg.sender] = newTotalRewards.sub(amountToClaim, 'INVALID_AMOUNT');

    uint256 stakedTokenRewardAmount = amountToClaim.percentMul(_stakedTokenRewardRatio);
    uint256 governanceTokenRewardAmount = amountToClaim.percentMul(PERCENTAGE_FACTOR - _stakedTokenRewardRatio);
    require(stakedTokenRewardAmount.add(governanceTokenRewardAmount) <= amountToClaim, 'INVALID_REWARD_AMOUNT');

    if (stakedTokenRewardAmount != 0) {
      GOVERNANCE_TOKEN.safeTransferFrom(REWARDS_VAULT, address(this), stakedTokenRewardAmount);

      // when Basic sKBT claimRewards
      if (stakedToken == address(this)) {
        _stake(address(this), to, stakedTokenRewardAmount);
      } else {
        IStakedToken(stakedToken).stake(to, stakedTokenRewardAmount);
      }
    }
    GOVERNANCE_TOKEN.safeTransferFrom(REWARDS_VAULT, to, governanceTokenRewardAmount);

    emit RewardsClaimed(msg.sender, to, stakedTokenRewardAmount, governanceTokenRewardAmount);
  }

  /**
   * @dev Internal KIP7 _transfer of the tokenized staked tokens
   * @param from Address to transfer from
   * @param to Address to transfer to
   * @param amount Amount to transfer
   **/
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    uint256 balanceOfFrom = balanceOf(from);
    // Sender
    _updateCurrentUnclaimedRewards(from, balanceOfFrom, true);

    // Recipient
    if (from != to) {
      uint256 balanceOfTo = balanceOf(to);
      _updateCurrentUnclaimedRewards(to, balanceOfTo, true);

      uint256 previousSenderHeatup = stakersHeatups[from];
      stakersHeatups[to] = getNextHeatupTimestamp(
        previousSenderHeatup,
        amount,
        to,
        balanceOfTo
      );
      // if heatup was set and whole balance of sender was transferred - clear heatup
      if (balanceOfFrom == amount && previousSenderHeatup != 0) {
        stakersHeatups[from] = 0;
      }
    }

    super._transfer(from, to, amount);
  }

  /**
   * @dev Updates the user state related with his accrued rewards
   * @param user Address of the user
   * @param userBalance The current balance of the user
   * @param updateStorage Boolean flag used to update or not the stakerRewardsToClaim of the user
   * @return The unclaimed rewards that were added to the total accrued
   **/
  function _updateCurrentUnclaimedRewards(
    address user,
    uint256 userBalance,
    bool updateStorage
  ) internal returns (uint256) {
    uint256 accruedRewards =
    _updateUserAssetInternal(user, address(this), userBalance, totalSupply());
    uint256 unclaimedRewards = stakerRewardsToClaim[user].add(accruedRewards);

    if (accruedRewards != 0) {
      if (updateStorage) {
        stakerRewardsToClaim[user] = unclaimedRewards;
      }
      emit RewardsAccrued(user, accruedRewards);
    }

    return unclaimedRewards;
  }

  /**
   * @dev Calculates the how is gonna be a new heatup timestamp depending on the sender/receiver situation
   *  - If the timestamp of the sender is "better" or the timestamp of the recipient is 0, we take the one of the recipient
   *  - Weighted average of from/to heatup timestamps if:
   *    # The sender doesn't have the heatup activated (timestamp 0).
   *    # The sender timestamp is expired
   *    # The sender has a "worse" timestamp
   *  - If the receiver's heatup timestamp expired (too old), the next is 0
   * @param fromHeatupTimestamp Heatup timestamp of the sender
   * @param amountToReceive Amount
   * @param toAddress Address of the recipient
   * @param toBalance Current balance of the receiver
   * @return The new heatup timestamp
   **/
  function getNextHeatupTimestamp(
    uint256 fromHeatupTimestamp,
    uint256 amountToReceive,
    address toAddress,
    uint256 toBalance
  ) public view returns (uint256) {
    uint256 toHeatupTimestamp = stakersHeatups[toAddress];
    if (toHeatupTimestamp == 0) {
      return 0;
    }

    uint256 minimalValidHeatupTimestamp =
    block.timestamp.sub(HEATUP_SECONDS).sub(UNSTAKE_WINDOW);

    if (minimalValidHeatupTimestamp > toHeatupTimestamp) {
      toHeatupTimestamp = 0;
    } else {
      uint256 fromHeatupTimestamp =
      (minimalValidHeatupTimestamp > fromHeatupTimestamp)
      ? block.timestamp
      : fromHeatupTimestamp;

      if (fromHeatupTimestamp < toHeatupTimestamp) {
        return toHeatupTimestamp;
      } else {
        toHeatupTimestamp = (
        amountToReceive.mul(fromHeatupTimestamp).add(toBalance.mul(toHeatupTimestamp))
        )
        .div(amountToReceive.add(toBalance));
      }
    }
    return toHeatupTimestamp;
  }

  /**
   * @dev Return the total rewards pending to claim by an staker
   * @param staker The staker address
   * @return The rewards
   */
  function getTotalRewardsBalance(address staker) external view returns (uint256) {
    DistributionTypes.UserStakeInput[] memory userStakeInputs =
    new DistributionTypes.UserStakeInput[](1);
    userStakeInputs[0] = DistributionTypes.UserStakeInput({
    underlyingAsset: address(this),
    stakedByUser: balanceOf(staker),
    totalStaked: totalSupply()
    });
    return stakerRewardsToClaim[staker].add(_getUnclaimedRewards(staker, userStakeInputs));
  }

  /**
   * @dev returns the revision of the implementation contract
   * @return The revision
   */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  function getStakedTokenRewardRatio() external view returns (uint16) {
    return _stakedTokenRewardRatio;
  }

  function setStakedTokenRewardRatio(uint16 stakedTokenRewardRatio) external onlyEmissionManager {
    require(stakedTokenRewardRatio <= PERCENTAGE_FACTOR, 'INVALID_REWARD_RATIO');
    _stakedTokenRewardRatio = stakedTokenRewardRatio;
    emit StakedTokenRewardRatioChanged(stakedTokenRewardRatio);
  }

  function setKlaybankGovernance(ITransferHook klaybankGovernance) external onlyEmissionManager {
    _setKlaybankGovernance(klaybankGovernance);
    emit SetKlaybankGovernance(address(klaybankGovernance));
  }

  /**
   * @dev implements the permit function as for https://github.com/ethereum/EIPs/blob/8a34d644aacf0f9f8f00815307fd7dd5da07655f/EIPS/eip-2612.md
   * @param owner the owner of the funds
   * @param spender the spender
   * @param value the amount
   * @param deadline the deadline timestamp, type(uint256).max for no deadline
   * @param v signature param
   * @param s signature param
   * @param r signature param
   */

  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    require(owner != address(0), 'INVALID_OWNER');
    //solium-disable-next-line
    require(block.timestamp <= deadline, 'INVALID_EXPIRATION');
    uint256 currentValidNonce = _nonces[owner];
    bytes32 digest =
    keccak256(
      abi.encodePacked(
        '\x19\x01',
        DOMAIN_SEPARATOR,
        keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, currentValidNonce, deadline))
      )
    );

    require(owner == ecrecover(digest, v, r, s), 'INVALID_SIGNATURE');
    _nonces[owner] = currentValidNonce.add(1);
    _approve(owner, spender, value);
  }

  /**
   * @dev Writes a snapshot before any operation involving transfer of value: _transfer, _mint and _burn
   * - On _transfer, it writes snapshots for both "from" and "to"
   * - On _mint, only for _to
   * - On _burn, only for _from
   * @param from the from address
   * @param to the to address
   * @param amount the amount to transfer
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    address votingFromDelegatee = _votingDelegates[from];
    address votingToDelegatee = _votingDelegates[to];

    if (votingFromDelegatee == address(0)) {
      votingFromDelegatee = from;
    }
    if (votingToDelegatee == address(0)) {
      votingToDelegatee = to;
    }

    _moveDelegatesByType(
      votingFromDelegatee,
      votingToDelegatee,
      amount,
      DelegationType.VOTING_POWER
    );

    address propPowerFromDelegatee = _propositionPowerDelegates[from];
    address propPowerToDelegatee = _propositionPowerDelegates[to];

    if (propPowerFromDelegatee == address(0)) {
      propPowerFromDelegatee = from;
    }
    if (propPowerToDelegatee == address(0)) {
      propPowerToDelegatee = to;
    }

    _moveDelegatesByType(
      propPowerFromDelegatee,
      propPowerToDelegatee,
      amount,
      DelegationType.PROPOSITION_POWER
    );

    // caching the klaybank governance address to avoid multiple state loads
    ITransferHook klaybankGovernance = _klaybankGovernance;
    if (klaybankGovernance != ITransferHook(0)) {
      klaybankGovernance.onTransfer(from, to, amount);
    }
  }

  function _getDelegationDataByType(DelegationType delegationType)
  internal
  view
  override
  returns (
    mapping(address => mapping(uint256 => Snapshot)) storage, //snapshots
    mapping(address => uint256) storage, //snapshots count
    mapping(address => address) storage //delegatees list
  )
  {
    if (delegationType == DelegationType.VOTING_POWER) {
      return (_votingSnapshots, _votingSnapshotsCounts, _votingDelegates);
    } else {
      return (
      _propositionPowerSnapshots,
      _propositionPowerSnapshotsCounts,
      _propositionPowerDelegates
      );
    }
  }

  /**
   * @dev Delegates power from signatory to `delegatee`
   * @param delegatee The address to delegate votes to
   * @param delegationType the type of delegation (VOTING_POWER, PROPOSITION_POWER)
   * @param nonce The contract state required to match the signature
   * @param expiry The time at which to expire the signature
   * @param v The recovery byte of the signature
   * @param r Half of the ECDSA signature pair
   * @param s Half of the ECDSA signature pair
   */
  function delegateByTypeBySig(
    address delegatee,
    DelegationType delegationType,
    uint256 nonce,
    uint256 expiry,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public {
    bytes32 structHash =
    keccak256(
      abi.encode(DELEGATE_BY_TYPE_TYPEHASH, delegatee, uint256(delegationType), nonce, expiry)
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', DOMAIN_SEPARATOR, structHash));
    address signatory = ecrecover(digest, v, r, s);
    require(signatory != address(0), 'INVALID_SIGNATURE');
    require(nonce == _nonces[signatory]++, 'INVALID_NONCE');
    require(block.timestamp <= expiry, 'INVALID_EXPIRATION');
    _delegateByType(signatory, delegatee, delegationType);
  }

  /**
   * @dev Delegates power from signatory to `delegatee`
   * @param delegatee The address to delegate votes to
   * @param nonce The contract state required to match the signature
   * @param expiry The time at which to expire the signature
   * @param v The recovery byte of the signature
   * @param r Half of the ECDSA signature pair
   * @param s Half of the ECDSA signature pair
   */
  function delegateBySig(
    address delegatee,
    uint256 nonce,
    uint256 expiry,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public {
    bytes32 structHash = keccak256(abi.encode(DELEGATE_TYPEHASH, delegatee, nonce, expiry));
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', DOMAIN_SEPARATOR, structHash));
    address signatory = ecrecover(digest, v, r, s);
    require(signatory != address(0), 'INVALID_SIGNATURE');
    require(nonce == _nonces[signatory]++, 'INVALID_NONCE');
    require(block.timestamp <= expiry, 'INVALID_EXPIRATION');
    _delegateByType(signatory, delegatee, DelegationType.VOTING_POWER);
    _delegateByType(signatory, delegatee, DelegationType.PROPOSITION_POWER);
  }
}
