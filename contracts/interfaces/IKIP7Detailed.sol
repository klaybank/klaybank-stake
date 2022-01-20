// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;

import {IKIP7} from './IKIP7.sol';

/**
 * @dev Interface for KIP7 including metadata
 **/
interface IKIP7Detailed is IKIP7 {
  function name() external view returns (string memory);

  function symbol() external view returns (string memory);

  function decimals() external view returns (uint8);
}
