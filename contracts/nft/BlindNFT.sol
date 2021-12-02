// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./interfaces/IPAWNFT.sol";

contract BlindNFT is IPAWNFT, ERC721PausableUpgradeable, OwnableUpgradeable, AccessControlUpgradeable {
  using SafeMathUpgradeable for uint256;
  using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
  using CountersUpgradeable for CountersUpgradeable.Counter;

  bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE"); // role for minting stuff (owner + some delegated contract eg nft market)

  struct Item {
    address nft;
    uint256 category; // category URI, a super set of token's uri (it can be either uri or a path (if specify a base URI))
    uint256 maxSupply;
    uint256 remaining;
  }

  bytes32 private lastHash;
  EnumerableSetUpgradeable.UintSet private openIds;
  CountersUpgradeable.Counter private tokenIdCount;
  Item[] public items;

  event OpenBox(uint256 indexed tokenId, address nft, uint256 category);

  function initialize(
    string memory _name,
    string memory _symbol,
    string memory _baseURI
  ) external initializer {
    ERC721Upgradeable.__ERC721_init(_name, _symbol);
    ERC721PausableUpgradeable.__ERC721Pausable_init();
    OwnableUpgradeable.__Ownable_init();
    PausableUpgradeable.__Pausable_init();
    AccessControlUpgradeable.__AccessControl_init();
    _setupRole(GOVERNANCE_ROLE, _msgSender());
    _setupRole(MINTER_ROLE, _msgSender());
    _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

    _setBaseURI(_baseURI);
    lastHash = keccak256(abi.encode(address(this), msg.sender, block.number));
  }

  function addItem(
    address _nft,
    uint256 _category,
    uint256 _maxSupply
  ) public onlyOwner {
    items.push(Item({ nft: _nft, category: _category, maxSupply: _maxSupply, remaining: _maxSupply }));
  }

  function sortItems() public {
    quickSortItem(int256(0), int256(items.length - 1));
  }

  function quickSortItem(int256 left, int256 right) internal {
    int256 i = left;
    int256 j = right;
    if (i == j) return;
    uint256 pivot = items[uint256(left + (right - left) / 2)].remaining;
    while (i <= j) {
      while (items[uint256(i)].remaining < pivot) i++;
      while (pivot < items[uint256(j)].remaining) j--;
      if (i <= j) {
        Item memory tmp = items[uint256(i)];
        items[uint256(i)] = items[uint256(j)];
        items[uint256(j)] = tmp;
        // (items[uint256(i)], items[uint256(j)]) = (items[uint256(j)], items[uint256(i)]);
        i++;
        j--;
      }
    }
    if (left < j) quickSortItem(left, j);
    if (i < right) quickSortItem(i, right);
  }

  function sumItems(uint256 n) internal view returns (uint256) {
    uint256 sum = 0;
    for (uint256 i = 0; i < n; i++) {
      sum = sum + items[i].remaining;
    }
    return sum;
  }

  function isIdOpen(uint256 tokenId) public view returns (bool) {
    return openIds.contains(tokenId);
  }

  function itemsLength() public view returns (uint256) {
    return items.length;
  }

  /// @notice return latest token id
  /// @return uint256 of the current token id
  function currentTokenId() public view override returns (uint256) {
    return tokenIdCount.current();
  }

  function openBox(uint256 tokenId) public onlyEOA {
    require(ownerOf(tokenId) == msg.sender, "BlindNFT::openBox::only open self box");
    require(!isIdOpen(tokenId), "BlindNFT::openBox::already open");
    openIds.add(tokenId);

    lastHash = keccak256(abi.encode(lastHash, msg.sender, tokenId, block.timestamp));

    uint256 seed = (uint256(lastHash) % sumItems(items.length)) + 1;
    sortItems();
    for (uint256 i = 0; i < items.length; i++) {
      if (seed < sumItems(i + 1) || (i == items.length - 1 && seed == sumItems(i + 1))) {
        items[i].remaining = items[i].remaining - 1;
        IPAWNFT(items[i].nft).mint(msg.sender, items[i].category, "");
        emit OpenBox(tokenId, items[i].nft, items[i].category);
        break;
      }
    }
  }

  function mint(
    address _to,
    uint256,
    string calldata
  ) public override onlyMinter whenNotPaused returns (uint256) {
    uint256 newId = tokenIdCount.current();
    tokenIdCount.increment();
    _mint(_to, newId);
    return newId;
  }

  function mintBatch(
    address _to,
    uint256 _categoryId,
    string calldata _tokenURI,
    uint256 _size
  ) external override onlyMinter whenNotPaused returns (uint256[] memory tokenIds) {
    require(_size != 0, "BlindNFT::mintBatch::size must be granter than zero");
    tokenIds = new uint256[](_size);
    for (uint256 i = 0; i < _size; ++i) {
      tokenIds[i] = mint(_to, _categoryId, _tokenURI);
    }
    return tokenIds;
  }

  function tokenURI(uint256)
    public
    view
    virtual
    override(ERC721Upgradeable, IERC721MetadataUpgradeable)
    returns (string memory)
  {
    return baseURI();
  }

  function pawNames(uint256) external view override returns (string memory) {
    return name();
  }

  function currentCategoryId() external view override returns (uint256) {}

  function categoryURI(uint256 categoryId) external view override returns (string memory) {}

  function getPAWNameOfTokenId(uint256 tokenId) external view override returns (string memory) {}

  function categoryInfo(uint256)
    external
    view
    override
    returns (
      string memory,
      string memory,
      uint256
    )
  {
    return (name(), baseURI(), block.timestamp);
  }

  function pawNFTToCategory(uint256) external view override returns (uint256) {
    return uint256(0);
  }

  function categoryToPAWNFTList(uint256 categoryId) external view override returns (uint256[] memory) {}

  /// @notice only GOVERNANCE ROLE (role that can setup NON sensitive parameters) can continue the execution
  modifier onlyGovernance() {
    require(hasRole(GOVERNANCE_ROLE, _msgSender()), "BlindNFT::onlyGovernance::only GOVERNANCE role");
    _;
  }

  /// @dev only the one having a MINTER_ROLE can continue an execution
  modifier onlyMinter() {
    require(hasRole(MINTER_ROLE, _msgSender()), "BlindNFT::onlyMinter::only MINTER role");
    _;
  }

  /// @dev Require that the caller must be an EOA account to avoid flash loans.
  modifier onlyEOA() {
    require(msg.sender == tx.origin, "Booster::onlyEOA:: not eoa");
    _;
  }
}
