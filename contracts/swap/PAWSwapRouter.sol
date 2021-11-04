// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.6.12;

import "./libraries/PAWSwapLibrary.sol";
import "./libraries/PAWSwapSafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/IPAWSwapRouter.sol";
import "./interfaces/IPAWSwapFactory.sol";
import "./interfaces/IPAWSwapBEP20.sol";
import "./interfaces/IWBNB.sol";

contract PAWSwapRouter is IPAWSwapRouter {
  using PAWSwapSafeMath for uint256;

  address public immutable override factory;
  address public immutable override WBNB;

  modifier ensure(uint256 deadline) {
    require(deadline >= block.timestamp, "PAWSwapRouter::ensure::EXPIRED");
    _;
  }

  constructor(address _factory, address _WBNB) public {
    factory = _factory;
    WBNB = _WBNB;
  }

  receive() external payable {
    assert(msg.sender == WBNB); // only accept ETH via fallback from the WBNB contract
  }

  // **** ADD LIQUIDITY ****
  function _addLiquidity(
    address tokenA,
    address tokenB,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin
  ) internal virtual returns (uint256 amountA, uint256 amountB) {
    // create the pair if it doesn't exist yet
    if (IPAWSwapFactory(factory).getPair(tokenA, tokenB) == address(0)) {
      IPAWSwapFactory(factory).createPair(tokenA, tokenB);
    }
    (uint256 reserveA, uint256 reserveB) = PAWSwapLibrary.getReserves(factory, tokenA, tokenB);
    if (reserveA == 0 && reserveB == 0) {
      (amountA, amountB) = (amountADesired, amountBDesired);
    } else {
      uint256 amountBOptimal = PAWSwapLibrary.quote(amountADesired, reserveA, reserveB);
      if (amountBOptimal <= amountBDesired) {
        require(amountBOptimal >= amountBMin, "PAWSwapRouter::_addLiquidity::INSUFFICIENT_B_AMOUNT");
        (amountA, amountB) = (amountADesired, amountBOptimal);
      } else {
        uint256 amountAOptimal = PAWSwapLibrary.quote(amountBDesired, reserveB, reserveA);
        assert(amountAOptimal <= amountADesired);
        require(amountAOptimal >= amountAMin, "PAWSwapRouter::_addLiquidity::INSUFFICIENT_A_AMOUNT");
        (amountA, amountB) = (amountAOptimal, amountBDesired);
      }
    }
  }

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  )
    external
    virtual
    override
    ensure(deadline)
    returns (
      uint256 amountA,
      uint256 amountB,
      uint256 liquidity
    )
  {
    (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
    address pair = PAWSwapLibrary.pairFor(factory, tokenA, tokenB);
    TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
    TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
    liquidity = IPAWSwapPair(pair).mint(to);
  }

  function addLiquidityETH(
    address token,
    uint256 amountTokenDesired,
    uint256 amountTokenMin,
    uint256 amountETHMin,
    address to,
    uint256 deadline
  )
    external
    payable
    virtual
    override
    ensure(deadline)
    returns (
      uint256 amountToken,
      uint256 amountETH,
      uint256 liquidity
    )
  {
    (amountToken, amountETH) = _addLiquidity(token, WBNB, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);
    address pair = PAWSwapLibrary.pairFor(factory, token, WBNB);
    TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
    IWBNB(WBNB).deposit{ value: amountETH }();
    assert(IWBNB(WBNB).transfer(pair, amountETH));
    liquidity = IPAWSwapPair(pair).mint(to);
    // refund dust eth, if any
    if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
  }

  // **** REMOVE LIQUIDITY ****
  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  ) public virtual override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
    address pair = PAWSwapLibrary.pairFor(factory, tokenA, tokenB);
    IPAWSwapPair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
    (uint256 amount0, uint256 amount1) = IPAWSwapPair(pair).burn(to);
    (address token0, ) = PAWSwapLibrary.sortTokens(tokenA, tokenB);
    (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    require(amountA >= amountAMin, "PAWSwapRouter::removeLiquidity::INSUFFICIENT_A_AMOUNT");
    require(amountB >= amountBMin, "PAWSwapRouter::removeLiquidity::INSUFFICIENT_B_AMOUNT");
  }

  function removeLiquidityETH(
    address token,
    uint256 liquidity,
    uint256 amountTokenMin,
    uint256 amountETHMin,
    address to,
    uint256 deadline
  ) public virtual override ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
    (amountToken, amountETH) = removeLiquidity(
      token,
      WBNB,
      liquidity,
      amountTokenMin,
      amountETHMin,
      address(this),
      deadline
    );
    TransferHelper.safeTransfer(token, to, amountToken);
    IWBNB(WBNB).withdraw(amountETH);
    TransferHelper.safeTransferETH(to, amountETH);
  }

  function removeLiquidityWithPermit(
    address tokenA,
    address tokenB,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline,
    bool approveMax,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external virtual override returns (uint256 amountA, uint256 amountB) {
    address pair = PAWSwapLibrary.pairFor(factory, tokenA, tokenB);
    uint256 value = approveMax ? uint256(-1) : liquidity;
    IPAWSwapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
  }

  function removeLiquidityETHWithPermit(
    address token,
    uint256 liquidity,
    uint256 amountTokenMin,
    uint256 amountETHMin,
    address to,
    uint256 deadline,
    bool approveMax,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external virtual override returns (uint256 amountToken, uint256 amountETH) {
    address pair = PAWSwapLibrary.pairFor(factory, token, WBNB);
    uint256 value = approveMax ? uint256(-1) : liquidity;
    IPAWSwapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
  }

  // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
  function removeLiquidityETHSupportingFeeOnTransferTokens(
    address token,
    uint256 liquidity,
    uint256 amountTokenMin,
    uint256 amountETHMin,
    address to,
    uint256 deadline
  ) public virtual override ensure(deadline) returns (uint256 amountETH) {
    (, amountETH) = removeLiquidity(token, WBNB, liquidity, amountTokenMin, amountETHMin, address(this), deadline);
    TransferHelper.safeTransfer(token, to, IPAWSwapBEP20(token).balanceOf(address(this)));
    IWBNB(WBNB).withdraw(amountETH);
    TransferHelper.safeTransferETH(to, amountETH);
  }

  function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
    address token,
    uint256 liquidity,
    uint256 amountTokenMin,
    uint256 amountETHMin,
    address to,
    uint256 deadline,
    bool approveMax,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external virtual override returns (uint256 amountETH) {
    address pair = PAWSwapLibrary.pairFor(factory, token, WBNB);
    uint256 value = approveMax ? uint256(-1) : liquidity;
    IPAWSwapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
      token,
      liquidity,
      amountTokenMin,
      amountETHMin,
      to,
      deadline
    );
  }

  // **** SWAP ****
  // requires the initial amount to have already been sent to the first pair
  function _swap(
    uint256[] memory amounts,
    address[] memory path,
    address _to
  ) internal virtual {
    for (uint256 i; i < path.length - 1; i++) {
      (address input, address output) = (path[i], path[i + 1]);
      (address token0, ) = PAWSwapLibrary.sortTokens(input, output);
      uint256 amountOut = amounts[i + 1];
      (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
      address to = i < path.length - 2 ? PAWSwapLibrary.pairFor(factory, output, path[i + 2]) : _to;
      IPAWSwapPair(PAWSwapLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
    }
  }

  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
    amounts = PAWSwapLibrary.getAmountsOut(factory, amountIn, path);
    require(
      amounts[amounts.length - 1] >= amountOutMin,
      "PAWSwapRouter::swapExactTokensForTokens::INSUFFICIENT_OUTPUT_AMOUNT"
    );
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
    _swap(amounts, path, to);
  }

  function swapTokensForExactTokens(
    uint256 amountOut,
    uint256 amountInMax,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
    amounts = PAWSwapLibrary.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= amountInMax, "PAWSwapRouter::swapTokensForExactTokens::EXCESSIVE_INPUT_AMOUNT");
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
    _swap(amounts, path, to);
  }

  function swapExactETHForTokens(
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external payable virtual override ensure(deadline) returns (uint256[] memory amounts) {
    require(path[0] == WBNB, "PAWSwapRouter::swapExactETHForTokens::INVALID_PATH");
    amounts = PAWSwapLibrary.getAmountsOut(factory, msg.value, path);
    require(
      amounts[amounts.length - 1] >= amountOutMin,
      "PAWSwapRouter::swapExactETHForTokens::INSUFFICIENT_OUTPUT_AMOUNT"
    );
    IWBNB(WBNB).deposit{ value: amounts[0] }();
    assert(IWBNB(WBNB).transfer(PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
    _swap(amounts, path, to);
  }

  function swapTokensForExactETH(
    uint256 amountOut,
    uint256 amountInMax,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
    require(path[path.length - 1] == WBNB, "PAWSwapRouter::swapTokensForExactETH::INVALID_PATH");
    amounts = PAWSwapLibrary.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= amountInMax, "PAWSwapRouter::swapTokensForExactETH::EXCESSIVE_INPUT_AMOUNT");
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
    _swap(amounts, path, address(this));
    IWBNB(WBNB).withdraw(amounts[amounts.length - 1]);
    TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
  }

  function swapExactTokensForETH(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
    require(path[path.length - 1] == WBNB, "PAWSwapRouter::swapExactTokensForETH::INVALID_PATH");
    amounts = PAWSwapLibrary.getAmountsOut(factory, amountIn, path);
    require(
      amounts[amounts.length - 1] >= amountOutMin,
      "PAWSwapRouter:swapExactTokensForETH::INSUFFICIENT_OUTPUT_AMOUNT"
    );
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
    _swap(amounts, path, address(this));
    IWBNB(WBNB).withdraw(amounts[amounts.length - 1]);
    TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
  }

  function swapETHForExactTokens(
    uint256 amountOut,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external payable virtual override ensure(deadline) returns (uint256[] memory amounts) {
    require(path[0] == WBNB, "PAWSwapRouter::swapETHForExactTokens::INVALID_PATH");
    amounts = PAWSwapLibrary.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= msg.value, "PAWSwapRouter::swapETHForExactTokens::EXCESSIVE_INPUT_AMOUNT");
    IWBNB(WBNB).deposit{ value: amounts[0] }();
    assert(IWBNB(WBNB).transfer(PAWSwapLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
    _swap(amounts, path, to);
    // refund dust eth, if any
    if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
  }

  // **** SWAP (supporting fee-on-transfer tokens) ****
  // requires the initial amount to have already been sent to the first pair
  function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
    for (uint256 i; i < path.length - 1; i++) {
      (address input, address output) = (path[i], path[i + 1]);
      (address token0, ) = PAWSwapLibrary.sortTokens(input, output);
      IPAWSwapPair pair = IPAWSwapPair(PAWSwapLibrary.pairFor(factory, input, output));
      uint256 amountInput;
      uint256 amountOutput;
      {
        // scope to avoid stack too deep errors
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint256 reserveInput, uint256 reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        amountInput = IPAWSwapBEP20(input).balanceOf(address(pair)).sub(reserveInput);
        amountOutput = PAWSwapLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
      }
      (uint256 amount0Out, uint256 amount1Out) = input == token0
        ? (uint256(0), amountOutput)
        : (amountOutput, uint256(0));
      address to = i < path.length - 2 ? PAWSwapLibrary.pairFor(factory, output, path[i + 2]) : _to;
      pair.swap(amount0Out, amount1Out, to, new bytes(0));
    }
  }

  function swapExactTokensForTokensSupportingFeeOnTransferTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) {
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amountIn);
    uint256 balanceBefore = IPAWSwapBEP20(path[path.length - 1]).balanceOf(to);
    _swapSupportingFeeOnTransferTokens(path, to);
    require(
      IPAWSwapBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
      "PAWSwapRouter::swapExactTokensForTokensSupportingFeeOnTransferTokens::INSUFFICIENT_OUTPUT_AMOUNT"
    );
  }

  function swapExactETHForTokensSupportingFeeOnTransferTokens(
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external payable virtual override ensure(deadline) {
    require(path[0] == WBNB, "PAWSwapRouter::swapExactETHForTokensSupportingFeeOnTransferTokens::INVALID_PATH");
    uint256 amountIn = msg.value;
    IWBNB(WBNB).deposit{ value: amountIn }();
    assert(IWBNB(WBNB).transfer(PAWSwapLibrary.pairFor(factory, path[0], path[1]), amountIn));
    uint256 balanceBefore = IPAWSwapBEP20(path[path.length - 1]).balanceOf(to);
    _swapSupportingFeeOnTransferTokens(path, to);
    require(
      IPAWSwapBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
      "PAWSwapRouter::swapExactETHForTokensSupportingFeeOnTransferTokens::INSUFFICIENT_OUTPUT_AMOUNT"
    );
  }

  function swapExactTokensForETHSupportingFeeOnTransferTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external virtual override ensure(deadline) {
    require(
      path[path.length - 1] == WBNB,
      "PAWSwapRouter::swapExactTokensForETHSupportingFeeOnTransferTokens::INVALID_PATH"
    );
    TransferHelper.safeTransferFrom(path[0], msg.sender, PAWSwapLibrary.pairFor(factory, path[0], path[1]), amountIn);
    _swapSupportingFeeOnTransferTokens(path, address(this));
    uint256 amountOut = IPAWSwapBEP20(WBNB).balanceOf(address(this));
    require(
      amountOut >= amountOutMin,
      "PAWSwapRouter::swapExactTokensForETHSupportingFeeOnTransferTokens::INSUFFICIENT_OUTPUT_AMOUNT"
    );
    IWBNB(WBNB).withdraw(amountOut);
    TransferHelper.safeTransferETH(to, amountOut);
  }

  // **** LIBRARY FUNCTIONS ****
  function quote(
    uint256 amountA,
    uint256 reserveA,
    uint256 reserveB
  ) external pure virtual override returns (uint256 amountB) {
    return PAWSwapLibrary.quote(amountA, reserveA, reserveB);
  }

  function getAmountOut(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 reserveOut
  ) external pure virtual override returns (uint256 amountOut) {
    return PAWSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
  }

  function getAmountIn(
    uint256 amountOut,
    uint256 reserveIn,
    uint256 reserveOut
  ) external pure virtual override returns (uint256 amountIn) {
    return PAWSwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
  }

  function getAmountsOut(uint256 amountIn, address[] memory path)
    external
    view
    virtual
    override
    returns (uint256[] memory amounts)
  {
    return PAWSwapLibrary.getAmountsOut(factory, amountIn, path);
  }

  function getAmountsIn(uint256 amountOut, address[] memory path)
    external
    view
    virtual
    override
    returns (uint256[] memory amounts)
  {
    return PAWSwapLibrary.getAmountsIn(factory, amountOut, path);
  }
}
