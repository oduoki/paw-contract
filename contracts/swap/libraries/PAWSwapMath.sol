// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.6.12;

// a library for performing various math operations
library PAWSwapMath {
  function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
    z = x < y ? x : y;
  }

  // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
  // reference: https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol#L687
  function sqrt(uint256 x) internal pure returns (uint256 z) {
    if (x == 0) return 0;
    uint256 xx = x;
    uint256 r = 1;

    if (xx >= 0x100000000000000000000000000000000) {
      xx >>= 128;
      r <<= 64;
    }

    if (xx >= 0x10000000000000000) {
      xx >>= 64;
      r <<= 32;
    }
    if (xx >= 0x100000000) {
      xx >>= 32;
      r <<= 16;
    }
    if (xx >= 0x10000) {
      xx >>= 16;
      r <<= 8;
    }
    if (xx >= 0x100) {
      xx >>= 8;
      r <<= 4;
    }
    if (xx >= 0x10) {
      xx >>= 4;
      r <<= 2;
    }
    if (xx >= 0x8) {
      r <<= 1;
    }

    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1;
    r = (r + x / r) >> 1; // Seven iterations should be enough
    uint256 r1 = x / r;
    return (r < r1 ? r : r1);
  }
}
