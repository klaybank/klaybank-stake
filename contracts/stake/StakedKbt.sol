// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;

import {IKIP7} from '../interfaces/IKIP7.sol';
import {StakedToken} from './StakedToken.sol';

/**
 * @title StakedKbt
 * @notice StakedToken with KBT token as staked token
 * @author Aave
 **/
contract StakedKbt is StakedToken {
  constructor(
    IKIP7 stakedToken,
    uint256 heatupSeconds,
    uint256 unstakeWindow,
    address rewardsVault,
    address emissionManager,
    string memory name,
    string memory symbol,
    uint8 decimals
  )
  public
  StakedToken(
    stakedToken,
    heatupSeconds,
    unstakeWindow,
    rewardsVault,
    emissionManager,
    name,
    symbol,
    decimals
  )
  {}
}
