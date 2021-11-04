// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

contract RandomMint {
  event Mint(uint256[]);

  bytes32 globalHash = keccak256("LOOTSWAG");
  bytes32 mask4 = 0xffffffff00000000000000000000000000000000000000000000000000000000;

  function mint8times() public returns (uint256[] memory) {
    globalHash = keccak256(abi.encode(globalHash, msg.sender, block.number));

    uint256[] memory allIds = initArray101();
    uint256 length = allIds.length;
    uint256[] memory selectedIds = new uint256[](8);
    for (uint256 i = 0; i < 8; i++) {
      bytes4 seed = bytes4((globalHash << (i * 4 * 8)) & mask4);
      uint256 selectedIndex = uint32(seed) % length;
      selectedIds[i] = allIds[selectedIndex];

      //delete used one
      allIds[selectedIndex] = allIds[length - 1];
      length--;
    }
    emit Mint(selectedIds);
    return selectedIds;
  }

  function initArray101() public pure returns (uint256[] memory) {
    uint256[] memory newArray = new uint256[](101);
    for (uint256 i = 0; i < 101; i++) {
      newArray[i] = i;
    }
    return newArray;
  }
}
