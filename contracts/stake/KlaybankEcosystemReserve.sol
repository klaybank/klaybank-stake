// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;

import {IKIP7} from '../interfaces/IKIP7.sol';
import {SafeKIP7} from '../lib/SafeKIP7.sol';
import {VersionedInitializable} from '../utils/VersionedInitializable.sol';

/**
 * @title KlaybankEcosystemReserve
 * @notice Stores all the KBT kept for incentives, just giving approval to the different
 * systems that will pull KBT funds for their specific use case
 * @author Aave
 **/
contract KlaybankEcosystemReserve is VersionedInitializable {
  using SafeKIP7 for IKIP7;

  event NewFundsAdmin(address indexed fundsAdmin);

  address internal _fundsAdmin;

  uint256 public constant REVISION = 2;

  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  function getFundsAdmin() external view returns (address) {
    return _fundsAdmin;
  }

  modifier onlyFundsAdmin() {
    require(msg.sender == _fundsAdmin, 'ONLY_BY_FUNDS_ADMIN');
    _;
  }

  function initialize(address reserveController) external initializer {
    _setFundsAdmin(reserveController);
  }

  function approve(
    IKIP7 token,
    address recipient,
    uint256 amount
  ) external onlyFundsAdmin {
    token.approve(recipient, amount);
  }

  function transfer(
    IKIP7 token,
    address recipient,
    uint256 amount
  ) external onlyFundsAdmin {
    token.transfer(recipient, amount);
  }

  function setFundsAdmin(address admin) public onlyFundsAdmin {
    _setFundsAdmin(admin);
  }

  function _setFundsAdmin(address admin) internal {
    _fundsAdmin = admin;
    emit NewFundsAdmin(admin);
  }
}
