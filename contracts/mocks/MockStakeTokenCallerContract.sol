// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../farm/interfaces/IMasterPAWCallback.sol";
import "../farm/interfaces/IMasterPAW.sol";

contract MockStakeTokenCallerContract is IMasterPAWCallback {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  address public stakeToken;
  address public PAW;
  IMasterPAW public MasterPAW;

  event OnBeforeLock();

  constructor(
    address _PAW,
    address _stakeToken,
    IMasterPAW _MasterPAW
  ) public {
    PAW = _PAW;
    stakeToken = _stakeToken;
    MasterPAW = _MasterPAW;
  }

  function _withdrawFromMasterPAW(IERC20 _stakeToken, uint256 _shares) internal returns (uint256 reward) {
    if (_shares == 0) return 0;
    uint256 stakeTokenBalance = _stakeToken.balanceOf(address(this));
    if (address(_stakeToken) == address(PAW)) {
      MasterPAW.withdrawPAW(msg.sender, _shares);
    } else {
      MasterPAW.withdraw(msg.sender, address(_stakeToken), _shares);
    }
    reward = address(PAW) == address(_stakeToken)
      ? _stakeToken.balanceOf(address(this)).sub(stakeTokenBalance)
      : IERC20(PAW).balanceOf(address(this));
    return reward;
  }

  function _harvestFromMasterPAW(IERC20 _stakeToken) internal returns (uint256 reward) {
    uint256 stakeTokenBalance = _stakeToken.balanceOf(address(this));
    (uint256 userStakeAmount, , , ) = MasterPAW.userInfo(address(address(_stakeToken)), msg.sender);

    if (userStakeAmount == 0) return 0;

    MasterPAW.harvest(msg.sender, address(_stakeToken));
    reward = address(PAW) == address(_stakeToken)
      ? _stakeToken.balanceOf(address(this)).sub(stakeTokenBalance)
      : IERC20(PAW).balanceOf(address(this));
    return reward;
  }

  function stake(IERC20 _stakeToken, uint256 _amount) external {
    _harvestFromMasterPAW(_stakeToken);

    IERC20(_stakeToken).safeApprove(address(MasterPAW), uint256(-1));
    if (address(_stakeToken) == address(PAW)) {
      MasterPAW.depositPAW(msg.sender, _amount);
    } else {
      MasterPAW.deposit(msg.sender, address(_stakeToken), _amount);
    }
  }

  function _unstake(IERC20 _stakeToken, uint256 _amount) internal {
    _withdrawFromMasterPAW(_stakeToken, _amount);
  }

  function unstake(address _stakeToken, uint256 _amount) external {
    _unstake(IERC20(_stakeToken), _amount);
  }

  function harvest(address _stakeToken) external {
    _harvest(_stakeToken);
  }

  function _harvest(address _stakeToken) internal {
    _harvestFromMasterPAW(IERC20(_stakeToken));
  }

  function masterPAWCall(
    address, /*stakeToken*/
    address, /*userAddr*/
    uint256, /*reward*/
    uint256 /*lastRewardBlock*/
  ) external override {
    emit OnBeforeLock();
  }
}
