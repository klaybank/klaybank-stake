// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;

import {KIP7} from '../lib/KIP7.sol';
import {ITransferHook} from '../interfaces/ITransferHook.sol';
import {SafeMath} from '../lib/SafeMath.sol';
import {
GovernancePowerDelegationKIP7
} from './GovernancePowerDelegationKIP7.sol';

/**
 * @title KIP7WithSnapshot
 * @notice KIP7 including snapshots of balances on transfer-related actions
 * @author Aave
 **/
abstract contract GovernancePowerWithSnapshot is GovernancePowerDelegationKIP7 {
  using SafeMath for uint256;

  /**
   * @dev The following storage layout points to the prior StakedToken.sol implementation:
   * _snapshots => _votingSnapshots
   * _snapshotsCounts =>  _votingSnapshotsCounts
   * _klaybankGovernance => _klaybankGovernance
   */
  mapping(address => mapping(uint256 => Snapshot)) public _votingSnapshots;
  mapping(address => uint256) public _votingSnapshotsCounts;

  /// @dev reference to the Klaybank governance contract to call (if initialized) on _beforeTokenTransfer
  /// !!! IMPORTANT The Klaybank governance is considered a trustable contract, being its responsibility
  /// to control all potential reentrancies by calling back the this contract
  ITransferHook public _klaybankGovernance;

  function _setKlaybankGovernance(ITransferHook klaybankGovernance) internal virtual {
    _klaybankGovernance = klaybankGovernance;
  }
}
