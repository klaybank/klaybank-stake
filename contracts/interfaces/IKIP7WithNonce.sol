// SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import {IKIP7} from './IKIP7.sol';

interface IKIP7WithNonce is IKIP7 {
  function _nonces(address user) external view returns (uint256);
}
