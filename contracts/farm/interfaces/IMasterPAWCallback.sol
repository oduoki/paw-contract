// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMasterPAWCallback {
  function masterPAWCall(
    address stakeToken,
    address userAddr,
    uint256 unboostedReward,
    uint256 lastRewardBlock
  ) external;
}
