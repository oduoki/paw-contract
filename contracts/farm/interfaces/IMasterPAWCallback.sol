// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMasterPAWCallback {
  function masterPAWCall(
    address stakeToken,
    address userAddr,
    uint256 _extraReward
  ) external;

  function bubbleRewardLimit(
    address stakeToken,
    address userAddr,
    uint256 unboostedBubbleReward,
    uint256 unboostedReward
  ) external view returns (uint256);
}
