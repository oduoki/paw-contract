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

  uint256 public maxTotalSupply;
  address public targetNFT;
  uint256 public targetCategoryId;

  bytes32 private lastHash;
  EnumerableSetUpgradeable.UintSet private luckyIds;
  CountersUpgradeable.Counter private availableTokenIds;
  EnumerableSetUpgradeable.UintSet private openIds;

  event OpenBox(uint256 indexed tokenId, bool lucky);

  function initialize(
    string memory _name,
    string memory _symbol,
    uint256 _maxTotalSupply,
    string memory _baseURI,
    address _targetNFT,
    uint256 _targetCategoryId
  ) external initializer {
    ERC721Upgradeable.__ERC721_init(_name, _symbol);
    ERC721PausableUpgradeable.__ERC721Pausable_init();
    OwnableUpgradeable.__Ownable_init();
    PausableUpgradeable.__Pausable_init();
    AccessControlUpgradeable.__AccessControl_init();
    _setupRole(GOVERNANCE_ROLE, _msgSender());
    _setupRole(MINTER_ROLE, _msgSender());
    _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

    maxTotalSupply = _maxTotalSupply;
    _setBaseURI(_baseURI);
    availableTokenIds = CountersUpgradeable.Counter({ _value: maxTotalSupply });
    lastHash = keccak256(abi.encode(address(this), msg.sender, block.timestamp));

    targetNFT = _targetNFT;
    targetCategoryId = _targetCategoryId;
  }

  function initLuckNumber(uint256[] calldata _luckyIds) public onlyOwner {
    for (uint256 i = 0; i < _luckyIds.length; i++) {
      luckyIds.add(_luckyIds[i]);
    }
  }

  function queryLuckyIds() public view returns (uint256[] memory) {
    uint256[] memory tokenIds = new uint256[](luckyIds.length());
    for (uint256 i = 0; i < luckyIds.length(); i++) {
      tokenIds[i] = luckyIds.at(i);
    }
    return tokenIds;
  }

  function isIdLucky(uint256 tokenId) public view returns (bool) {
    return luckyIds.contains(tokenId);
  }

  function queryOpenIds() public view returns (uint256[] memory) {
    uint256[] memory tokenIds = new uint256[](openIds.length());
    for (uint256 i = 0; i < openIds.length(); i++) {
      tokenIds[i] = openIds.at(i);
    }
    return tokenIds;
  }

  function isIdOpen(uint256 tokenId) public view returns (bool) {
    return openIds.contains(tokenId);
  }

  function queryAvailableTokenIds() public view returns (uint256) {
    return availableTokenIds.current();
  }

  function openBox(uint256 tokenId) public {
    require(ownerOf(tokenId) == msg.sender, "BlindNFT::openBox::only open self box");
    require(!isIdOpen(tokenId), "BlindNFT::openBox::already open");
    openIds.add(tokenId);
    if (isIdLucky(tokenId)) {
      IPAWNFT(targetNFT).mint(msg.sender, targetCategoryId, "");
      emit OpenBox(tokenId, true);
    } else {
      emit OpenBox(tokenId, false);
    }
  }

  function mint(
    address _to,
    uint256,
    string calldata
  ) public override onlyMinter whenNotPaused returns (uint256) {
    require(availableTokenIds.current() > 0, "BlindNFT::mint::no available to mint");

    lastHash = keccak256(abi.encode(lastHash, _to, block.timestamp));
    uint256 seed = uint256(lastHash) & 0xffffff;
    seed = seed.mod(maxTotalSupply);
    uint256 tokenId = 0;
    //token id from [1...maxTotalSupply]
    for (uint256 index = 0; index < maxTotalSupply; index++) {
      uint256 _tokenId = seed.add(index).mod(maxTotalSupply).add(1);
      if (_tokenId != 0 && !_exists(_tokenId)) {
        tokenId = _tokenId;
        break;
      }
    }
    require(tokenId > 0, "BlindNFT::mint::must find a token id");
    _mint(_to, tokenId);
    availableTokenIds.decrement();
    return tokenId;
  }

  function mintBatch(
    address _to,
    uint256 _categoryId,
    string calldata _tokenURI,
    uint256 _size
  ) external override onlyMinter whenNotPaused returns (uint256[] memory tokenIds) {
    require(_size != 0, "BlindNFT::mintBatch::size must be granter than zero");
    require(_size <= availableTokenIds.current(), "BlindNFT::mintBatch::size must be lower than available");
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

  /// @notice return latest token id
  /// @return uint256 of the current token id
  function currentTokenId() public view override returns (uint256) {}

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
}
