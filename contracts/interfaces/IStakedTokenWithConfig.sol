// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import {IStakedToken} from '../interfaces/IStakedToken.sol';

interface IStakedTokenWithConfig is IStakedToken {
  function GOVERNANCE_TOKEN() external view returns(address);
}
