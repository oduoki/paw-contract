// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";

import "../library/LinkList.sol";
import "./interfaces/IPAW.sol";
import "./interfaces/IBeanBag.sol";
import "./interfaces/IMasterPAW.sol";
import "./interfaces/IMasterPAWCallback.sol";

/// @notice MasterPAW is a smart contract for distributing PAW by asking user to stake the BEP20-based token.
contract MasterPAW is
    IMasterPAW,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using LinkList for LinkList.List;
    using AddressUpgradeable for address;
    using MathUpgradeable for uint256;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many Staking tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 bonusDebt; // Last block that user exec something to the pool.
        uint256 bubbleRate;
        uint256 share;
        address fundedBy;
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 allocPoint; // How many allocation points assigned to this pool.
        uint256 lastRewardBlock; // Last block number that PAW distribution occurs.
        uint256 accPAWPerShare; // Accumulated PAW per share, times 1e12. See below.
        uint256 accPAWPerShareTilBonusEnd; // Accumated PAW per share until Bonus End.
        uint256 allocBps; // Pool allocation in BPS, if it's not a fixed bps pool, leave it 0
        uint256 shares; //all shares
    }

    // PAW token.
    IPAW public PAW;
    // BEAN token.
    IBeanBag public bean;
    // Dev address.
    address public override devAddr;
    uint256 public override devFeeBps;
    // PAW per block.
    uint256 public PAWPerBlock;
    // Bonus muliplier for early users.
    uint256 public bonusMultiplier;
    // Block number when bonus PAW period ends.
    uint256 public bonusEndBlock;
    // Bonus lock-up in BPS
    uint256 public bonusLockUpBps;

    // Info of each pool.
    // PoolInfo[] public poolInfo;
    // Pool link list
    LinkList.List public pools;
    // Pool Info
    mapping(address => PoolInfo) public poolInfo;
    // Info of each user that stakes Staking tokens.
    mapping(address => mapping(address => UserInfo)) public override userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    // The block number when PAW mining starts.
    uint256 public startBlock;

    // Does the pool allows some contracts to fund for an account
    mapping(address => bool) public stakeTokenCallerAllowancePool;

    // list of contracts that the pool allows to fund
    mapping(address => LinkList.List) public stakeTokenCallerContracts;

    event AddPool(
        address stakeToken,
        uint256 allocPoint,
        uint256 totalAllocPoint
    );
    event SetPool(
        address stakeToken,
        uint256 allocPoint,
        uint256 totalAllocPoint
    );
    event RemovePool(
        address stakeToken,
        uint256 allocPoint,
        uint256 totalAllocPoint
    );
    event Deposit(
        address indexed funder,
        address indexed fundee,
        address indexed stakeToken,
        uint256 amount
    );
    event Withdraw(
        address indexed funder,
        address indexed fundee,
        address indexed stakeToken,
        uint256 amount
    );
    event EmergencyWithdraw(
        address indexed user,
        address indexed stakeToken,
        uint256 amount
    );
    event BonusChanged(
        uint256 bonusMultiplier,
        uint256 bonusEndBlock,
        uint256 bonusLockUpBps
    );
    event PoolAllocChanged(
        address indexed pool,
        uint256 allocBps,
        uint256 allocPoint
    );
    event SetStakeTokenCallerAllowancePool(
        address indexed stakeToken,
        bool isAllowed
    );
    event AddStakeTokenCallerContract(
        address indexed stakeToken,
        address indexed caller
    );
    event RemoveStakeTokenCallerContract(
        address indexed stakeToken,
        address indexed caller
    );
    event MintExtraReward(
        address indexed sender,
        address indexed stakeToken,
        address indexed to,
        uint256 amount
    );
    event SetPAWPerBlock(uint256 prevPAWPerBlock, uint256 currentPAWPerBlock);
    event Harvest(
        address indexed caller,
        address indexed beneficiary,
        address indexed stakeToken,
        uint256 amount
    );

    /// @dev Initializer to create PAWMasterPAW instance + add pool(0)
    /// @param _PAW The address of PAW
    /// @param _devAddr The address that will PAW dev fee
    /// @param _PAWPerBlock The initial emission rate
    /// @param _startBlock The block that PAW will start to release
    function initialize(
        IPAW _PAW,
        IBeanBag _bean,
        address _devAddr,
        uint256 _PAWPerBlock,
        uint256 _startBlock
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        bonusMultiplier = 0;
        PAW = _PAW;
        bean = _bean;
        devAddr = _devAddr;
        devFeeBps = 1500;
        PAWPerBlock = _PAWPerBlock;
        startBlock = _startBlock;
        pools.init();

        // add PAW->PAW pool
        pools.add(address(_PAW));
        poolInfo[address(_PAW)] = PoolInfo({
            allocPoint: 0,
            lastRewardBlock: startBlock,
            accPAWPerShare: 0,
            accPAWPerShareTilBonusEnd: 0,
            allocBps: 0,
            shares: 0
        });
        totalAllocPoint = 0;
    }

    /// @dev only permitted funder can continue the execution
    /// @dev eg. if a pool accepted funders, then msg.sender needs to be those funders, otherwise it will be reverted
    /// @dev --  if a pool doesn't accepted any funders, then msg.sender needs to be the one with beneficiary (eoa account)
    /// @param _beneficiary is an address this funder funding for
    /// @param _stakeToken a stake token
    modifier onlyPermittedTokenFunder(
        address _beneficiary,
        address _stakeToken
    ) {
        require(
            _isFunder(_beneficiary, _stakeToken),
            "MasterPAW::onlyPermittedTokenFunder: caller is not permitted"
        );
        _;
    }

    /// @notice only permitted funder can continue the execution
    /// @dev eg. if a pool accepted funders (from setStakeTokenCallerAllowancePool), then msg.sender needs to be those funders, otherwise it will be reverted
    /// @dev --  if a pool doesn't accepted any funders, then msg.sender needs to be the one with beneficiary (eoa account)
    /// @param _beneficiary is an address this funder funding for
    /// @param _stakeTokens a set of stake token (when doing batch)
    modifier onlyPermittedTokensFunder(
        address _beneficiary,
        address[] calldata _stakeTokens
    ) {
        for (uint256 i = 0; i < _stakeTokens.length; i++) {
            require(
                _isFunder(_beneficiary, _stakeTokens[i]),
                "MasterPAW::onlyPermittedTokensFunder: caller is not permitted"
            );
        }
        _;
    }

    /// @dev only stake token caller contract can continue the execution (stakeTokenCaller must be a funder contract)
    /// @param _stakeToken a stakeToken to be validated
    modifier onlyStakeTokenCallerContract(address _stakeToken) {
        require(
            stakeTokenCallerContracts[_stakeToken].has(_msgSender()),
            "MasterPAW::onlyStakeTokenCallerContract: bad caller"
        );
        _;
    }

    /// @notice set funder allowance for a stake token pool
    /// @param _stakeToken a stake token to allow funder
    /// @param _isAllowed a parameter just like in doxygen (must be followed by parameter name)
    function setStakeTokenCallerAllowancePool(
        address _stakeToken,
        bool _isAllowed
    ) external onlyOwner {
        stakeTokenCallerAllowancePool[_stakeToken] = _isAllowed;

        emit SetStakeTokenCallerAllowancePool(_stakeToken, _isAllowed);
    }

    /// @notice Setter function for adding stake token contract caller
    /// @param _stakeToken a pool for adding a corresponding stake token contract caller
    /// @param _caller a stake token contract caller
    function addStakeTokenCallerContract(address _stakeToken, address _caller)
        external
        onlyOwner
    {
        require(
            stakeTokenCallerAllowancePool[_stakeToken],
            "MasterPAW::addStakeTokenCallerContract: the pool doesn't allow a contract caller"
        );
        LinkList.List storage list = stakeTokenCallerContracts[_stakeToken];
        if (list.getNextOf(LinkList.start) == LinkList.empty) {
            list.init();
        }
        list.add(_caller);
        emit AddStakeTokenCallerContract(_stakeToken, _caller);
    }

    /// @notice Setter function for removing stake token contract caller
    /// @param _stakeToken a pool for removing a corresponding stake token contract caller
    /// @param _caller a stake token contract caller
    function removeStakeTokenCallerContract(
        address _stakeToken,
        address _caller
    ) external onlyOwner {
        require(
            stakeTokenCallerAllowancePool[_stakeToken],
            "MasterPAW::removeStakeTokenCallerContract: the pool doesn't allow a contract caller"
        );
        LinkList.List storage list = stakeTokenCallerContracts[_stakeToken];
        list.remove(_caller, list.getPreviousOf(_caller));

        emit RemoveStakeTokenCallerContract(_stakeToken, _caller);
    }

    /// @dev Update dev address by the previous dev.
    /// @param _devAddr The new dev address
    function setDev(address _devAddr) external {
        require(
            _msgSender() == devAddr,
            "MasterPAW::setDev::only prev dev can changed dev address"
        );
        devAddr = _devAddr;
    }

    /// @dev Set PAW per block.
    /// @param _PAWPerBlock The new emission rate for PAW
    function setPAWPerBlock(uint256 _PAWPerBlock) external onlyOwner {
        massUpdatePools();
        emit SetPAWPerBlock(PAWPerBlock, _PAWPerBlock);
        PAWPerBlock = _PAWPerBlock;
    }

    /// @dev Set a specified pool's alloc BPS
    /// @param _allocBps The new alloc Bps
    /// @param _stakeToken pid
    function setPoolAllocBps(address _stakeToken, uint256 _allocBps)
        external
        onlyOwner
    {
        require(
            _stakeToken != address(0) && _stakeToken != address(1),
            "MasterPAW::setPoolAllocBps::_stakeToken must not be address(0) or address(1)"
        );
        require(
            pools.has(_stakeToken),
            "MasterPAW::setPoolAllocBps::pool hasn't been set"
        );
        address curr = pools.next[LinkList.start];
        uint256 accumAllocBps = 0;
        while (curr != LinkList.end) {
            if (curr != _stakeToken) {
                accumAllocBps = accumAllocBps.add(poolInfo[curr].allocBps);
            }
            curr = pools.getNextOf(curr);
        }
        require(
            accumAllocBps.add(_allocBps) < 10000,
            "MasterPAW::setPoolallocBps::accumAllocBps must < 10000"
        );
        massUpdatePools();
        if (_allocBps == 0) {
            totalAllocPoint = totalAllocPoint.sub(
                poolInfo[_stakeToken].allocPoint
            );
            poolInfo[_stakeToken].allocPoint = 0;
        }
        poolInfo[_stakeToken].allocBps = _allocBps;
        updatePoolsAlloc();
    }

    /// @dev Set Bonus params. Bonus will start to accu on the next block that this function executed.
    /// @param _bonusMultiplier The new multiplier for bonus period.
    /// @param _bonusEndBlock The new end block for bonus period
    /// @param _bonusLockUpBps The new lock up in BPS
    function setBonus(
        uint256 _bonusMultiplier,
        uint256 _bonusEndBlock,
        uint256 _bonusLockUpBps
    ) external onlyOwner {
        require(
            _bonusEndBlock > block.number,
            "MasterPAW::setBonus::bad bonusEndBlock"
        );
        require(
            _bonusMultiplier > 1,
            "MasterPAW::setBonus::bad bonusMultiplier"
        );
        require(
            _bonusLockUpBps <= 10000,
            "MasterPAW::setBonus::bad bonusLockUpBps"
        );

        massUpdatePools();

        bonusMultiplier = _bonusMultiplier;
        bonusEndBlock = _bonusEndBlock;
        bonusLockUpBps = _bonusLockUpBps;

        emit BonusChanged(bonusMultiplier, bonusEndBlock, bonusLockUpBps);
    }

    /// @dev Add a pool. Can only be called by the owner.
    /// @param _stakeToken The token that needed to be staked to earn PAW.
    /// @param _allocPoint The allocation point of a new pool.
    function addPool(address _stakeToken, uint256 _allocPoint)
        external
        override
        onlyOwner
    {
        require(
            _stakeToken != address(0) && _stakeToken != address(1),
            "MasterPAW::addPool::_stakeToken must not be address(0) or address(1)"
        );
        require(
            !pools.has(_stakeToken),
            "MasterPAW::addPool::_stakeToken duplicated"
        );

        massUpdatePools();

        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pools.add(_stakeToken);
        poolInfo[_stakeToken] = PoolInfo({
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accPAWPerShare: 0,
            accPAWPerShareTilBonusEnd: 0,
            allocBps: 0,
            shares: 0
        });

        updatePoolsAlloc();

        emit AddPool(_stakeToken, _allocPoint, totalAllocPoint);
    }

    /// @dev Update the given pool's PAW allocation point. Can only be called by the owner.
    /// @param _stakeToken The pool id to be updated
    /// @param _allocPoint The new allocPoint
    function setPool(address _stakeToken, uint256 _allocPoint)
        external
        override
        onlyOwner
    {
        require(
            _stakeToken != address(0) && _stakeToken != address(1),
            "MasterPAW::setPool::_stakeToken must not be address(0) or address(1)"
        );
        require(
            pools.has(_stakeToken),
            "MasterPAW::setPool::_stakeToken not in the list"
        );

        massUpdatePools();

        totalAllocPoint = totalAllocPoint
            .sub(poolInfo[_stakeToken].allocPoint)
            .add(_allocPoint);
        uint256 prevAllocPoint = poolInfo[_stakeToken].allocPoint;
        poolInfo[_stakeToken].allocPoint = _allocPoint;

        if (prevAllocPoint != _allocPoint) {
            updatePoolsAlloc();
        }

        emit SetPool(_stakeToken, _allocPoint, totalAllocPoint);
    }

    /// @dev Remove pool. Can only be called by the owner.
    /// @param _stakeToken The stake token pool to be removed
    function removePool(address _stakeToken) external override onlyOwner {
        require(
            _stakeToken != address(PAW),
            "MasterPAW::removePool::can't remove PAW pool"
        );
        require(
            pools.has(_stakeToken),
            "MasterPAW::removePool::pool not add yet"
        );
        require(
            IERC20(_stakeToken).balanceOf(address(this)) == 0,
            "MasterPAW::removePool::pool not empty"
        );

        massUpdatePools();

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_stakeToken].allocPoint);

        pools.remove(_stakeToken, pools.getPreviousOf(_stakeToken));
        poolInfo[_stakeToken].allocPoint = 0;
        poolInfo[_stakeToken].lastRewardBlock = 0;
        poolInfo[_stakeToken].accPAWPerShare = 0;
        poolInfo[_stakeToken].accPAWPerShareTilBonusEnd = 0;
        poolInfo[_stakeToken].allocBps = 0;

        updatePoolsAlloc();

        emit RemovePool(_stakeToken, 0, totalAllocPoint);
    }

    /// @dev Update pools' alloc point
    function updatePoolsAlloc() internal {
        address curr = pools.next[LinkList.start];
        uint256 points = 0;
        uint256 accumAllocBps = 0;
        while (curr != LinkList.end) {
            if (poolInfo[curr].allocBps > 0) {
                accumAllocBps = accumAllocBps.add(poolInfo[curr].allocBps);
                curr = pools.getNextOf(curr);
                continue;
            }

            points = points.add(poolInfo[curr].allocPoint);
            curr = pools.getNextOf(curr);
        }

        // re-adjust an allocpoints for those pool having an allocBps
        if (points != 0) {
            _updatePoolAlloc(accumAllocBps, points);
        }
    }

    // @dev internal function for updating pool based on accumulated bps and points
    function _updatePoolAlloc(
        uint256 _accumAllocBps,
        uint256 _accumNonBpsPoolPoints
    ) internal {
        // n = kp/(1-k),
        // where  k is accumAllocBps
        // p is sum of points of other pools
        address curr = pools.next[LinkList.start];
        uint256 num = _accumNonBpsPoolPoints.mul(_accumAllocBps);
        uint256 denom = uint256(10000).sub(_accumAllocBps);
        uint256 poolPoints;
        while (curr != LinkList.end) {
            if (poolInfo[curr].allocBps == 0) {
                curr = pools.getNextOf(curr);
                continue;
            }
            poolPoints = (num.mul(poolInfo[curr].allocBps)).div(
                _accumAllocBps.mul(denom)
            );
            totalAllocPoint = totalAllocPoint
                .sub(poolInfo[curr].allocPoint)
                .add(poolPoints);
            poolInfo[curr].allocPoint = poolPoints;
            emit PoolAllocChanged(curr, poolInfo[curr].allocBps, poolPoints);
            curr = pools.getNextOf(curr);
        }
    }

    /// @dev Return the length of poolInfo
    function poolLength() external view override returns (uint256) {
        return pools.length();
    }

    /// @dev Return reward multiplier over the given _from to _to block.
    /// @param _lastRewardBlock The last block that rewards have been paid
    /// @param _currentBlock The current block
    function getMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock)
        private
        view
        returns (uint256)
    {
        if (_currentBlock <= bonusEndBlock) {
            return _currentBlock.sub(_lastRewardBlock).mul(bonusMultiplier);
        }
        if (_lastRewardBlock >= bonusEndBlock) {
            return _currentBlock.sub(_lastRewardBlock);
        }
        // This is the case where bonusEndBlock is in the middle of _lastRewardBlock and _currentBlock block.
        return
            bonusEndBlock.sub(_lastRewardBlock).mul(bonusMultiplier).add(
                _currentBlock.sub(bonusEndBlock)
            );
    }

    /// @notice validating if a msg sender is a funder
    /// @param _beneficiary if a stake token does't allow stake token contract caller, checking if a msg sender is the same with _beneficiary
    /// @param _stakeToken a stake token for checking a validity
    /// @return boolean result of validating if a msg sender is allowed to be a funder
    function _isFunder(address _beneficiary, address _stakeToken)
        internal
        view
        returns (bool)
    {
        if (stakeTokenCallerAllowancePool[_stakeToken])
            return stakeTokenCallerContracts[_stakeToken].has(_msgSender());
        return _beneficiary == _msgSender();
    }

    /// @dev View function to see pending PAWs on frontend.
    /// @param _stakeToken The stake token
    /// @param _user The address of a user
    function pendingPAW(address _stakeToken, address _user)
        external
        view
        override
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_stakeToken];
        UserInfo storage user = userInfo[_stakeToken][_user];
        uint256 accPAWPerShare = pool.accPAWPerShare;
        uint256 totalStakeToken = pool.shares;
        if (block.number > pool.lastRewardBlock && totalStakeToken != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 PAWReward = multiplier
                .mul(PAWPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accPAWPerShare = accPAWPerShare.add(
                PAWReward.mul(1e12).div(totalStakeToken)
            );
        }
        return user.share.mul(accPAWPerShare).div(1e12).sub(user.rewardDebt);
    }

    /// @dev Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        address curr = pools.next[LinkList.start];
        while (curr != LinkList.end) {
            updatePool(curr);
            curr = pools.getNextOf(curr);
        }
    }

    /// @dev Update reward variables of the given pool to be up-to-date.
    /// @param _stakeToken The stake token address of the pool to be updated
    function updatePool(address _stakeToken) public override {
        PoolInfo storage pool = poolInfo[_stakeToken];
        if (block.number <= pool.lastRewardBlock || totalAllocPoint == 0) {
            return;
        }
        uint256 totalStakeToken = pool.shares;
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 pawReward = multiplier
            .mul(PAWPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        if (pawReward == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if (totalStakeToken == 0) {
            PAW.mint(devAddr, pawReward);
            pool.lastRewardBlock = block.number;
            return;
        }
        PAW.mint(devAddr, pawReward.mul(devFeeBps).div(10000));
        PAW.mint(address(bean), pawReward);
        pool.accPAWPerShare = pool.accPAWPerShare.add(
            pawReward.mul(1e12).div(totalStakeToken)
        );
        // Clear bonus & update accPAWPerShareTilBonusEnd.
        if (block.number <= bonusEndBlock) {
            PAW.lock(
                devAddr,
                pawReward.mul(bonusLockUpBps).mul(15).div(1000000)
            );
            pool.accPAWPerShareTilBonusEnd = pool.accPAWPerShare;
        }
        if (
            block.number > bonusEndBlock && pool.lastRewardBlock < bonusEndBlock
        ) {
            uint256 PAWBonusPortion = bonusEndBlock
                .sub(pool.lastRewardBlock)
                .mul(bonusMultiplier)
                .mul(PAWPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            PAW.lock(
                devAddr,
                PAWBonusPortion.mul(bonusLockUpBps).mul(15).div(1000000)
            );
            pool.accPAWPerShareTilBonusEnd = pool.accPAWPerShareTilBonusEnd.add(
                PAWBonusPortion.mul(1e12).div(totalStakeToken)
            );
        }

        pool.lastRewardBlock = block.number;
    }

    /// @dev Deposit token to get PAW.
    /// @param _stakeToken The stake token to be deposited
    /// @param _amount The amount to be deposited
    function deposit(
        address _for,
        address _stakeToken,
        uint256 _amount
    )
        external
        override
        onlyPermittedTokenFunder(_for, _stakeToken)
        nonReentrant
    {
        require(
            _stakeToken != address(0) && _stakeToken != address(1),
            "MasterPAW::setPool::_stakeToken must not be address(0) or address(1)"
        );
        require(
            _stakeToken != address(PAW),
            "MasterPAW::deposit::use depositPAW instead"
        );
        require(pools.has(_stakeToken), "MasterPAW::deposit::no pool");

        PoolInfo storage pool = poolInfo[_stakeToken];
        UserInfo storage user = userInfo[_stakeToken][_for];

        if (user.fundedBy != address(0))
            require(
                user.fundedBy == _msgSender(),
                "MasterPAW::deposit::bad sof"
            );

        uint256 lastRewardBlock = pool.lastRewardBlock;
        updatePool(_stakeToken);

        if (user.amount > 0) _harvest(_for, _stakeToken, lastRewardBlock);
        if (user.fundedBy == address(0)) user.fundedBy = _msgSender();
        if (_amount > 0) {
            IERC20(_stakeToken).safeTransferFrom(
                address(_msgSender()),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
            pool.shares = pool.shares.add(_amount);
            user.share = user.share.add(_amount);
            if (user.bubbleRate > 0) {
                user.share = user.share.add(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
                pool.shares = pool.shares.add(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
            }
        }

        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );
        emit Deposit(_msgSender(), _for, _stakeToken, _amount);
    }

    function noBubble(address _for, address _stakeToken)
        external
        override
        nonReentrant
    {
        UserInfo storage user = userInfo[_stakeToken][_for];
        PoolInfo storage pool = poolInfo[_stakeToken];

        //permint by fundedBy
        if (user.fundedBy != address(0))
            require(
                user.fundedBy == _msgSender(),
                "MasterPAW::nobubble::bad sof"
            );
        user.bubbleRate = 0;

        pool.shares = pool.shares.sub(user.share.sub(user.amount));

        user.share = user.amount;
        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );
    }

    function bubble(
        address _for,
        address _stakeToken,
        uint256 _rate
    )
        external
        override
        onlyPermittedTokenFunder(_for, _stakeToken)
        nonReentrant
    {
        UserInfo storage user = userInfo[_stakeToken][_for];
        require(user.bubbleRate == 0, "already bubble");
        require(pools.has(_stakeToken), "MasterPAW::bubble::no pool");
        user.bubbleRate = _rate;
        uint256 _shareDif = user.amount.mul(user.bubbleRate).div(1e4);
        user.share = user.share.add(_shareDif);

        PoolInfo storage pool = poolInfo[_stakeToken];
        pool.shares = pool.shares.add(_shareDif);

        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );
    }

    /// @dev Withdraw token from PAWMasterPAW.
    /// @param _stakeToken The token to be withdrawn
    /// @param _amount The amount to be withdrew
    function withdraw(
        address _for,
        address _stakeToken,
        uint256 _amount
    ) external override nonReentrant {
        require(
            _stakeToken != address(0) && _stakeToken != address(1),
            "MasterPAW::setPool::_stakeToken must not be address(0) or address(1)"
        );
        require(
            _stakeToken != address(PAW),
            "MasterPAW::withdraw::use withdrawPAW instead"
        );
        require(pools.has(_stakeToken), "MasterPAW::withdraw::no pool");

        PoolInfo storage pool = poolInfo[_stakeToken];
        UserInfo storage user = userInfo[_stakeToken][_for];

        require(
            user.fundedBy == _msgSender(),
            "MasterPAW::withdraw::only funder"
        );
        require(user.amount >= _amount, "MasterPAW::withdraw::not good");

        uint256 lastRewardBlock = pool.lastRewardBlock;
        updatePool(_stakeToken);
        _harvest(_for, _stakeToken, lastRewardBlock);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.shares = pool.shares.sub(_amount);
            user.share = user.share.sub(_amount);

            if (user.bubbleRate > 0) {
                user.share = user.share.sub(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
                pool.shares = pool.shares.sub(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
            }
        }

        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );

        if (user.amount == 0) user.fundedBy = address(0);
        IERC20(_stakeToken).safeTransfer(_msgSender(), _amount);

        emit Withdraw(_msgSender(), _for, _stakeToken, user.amount);
    }

    /// @dev Deposit PAW to get even more PAW.
    /// @param _amount The amount to be deposited
    function depositPAW(address _for, uint256 _amount)
        external
        override
        onlyPermittedTokenFunder(_for, address(PAW))
        nonReentrant
    {
        PoolInfo storage pool = poolInfo[address(PAW)];
        UserInfo storage user = userInfo[address(PAW)][_for];

        if (user.fundedBy != address(0))
            require(
                user.fundedBy == _msgSender(),
                "MasterPAW::depositPAW::bad sof"
            );

        uint256 lastRewardBlock = pool.lastRewardBlock;
        updatePool(address(PAW));

        if (user.amount > 0) _harvest(_for, address(PAW), lastRewardBlock);
        if (user.fundedBy == address(0)) user.fundedBy = _msgSender();
        if (_amount > 0) {
            IERC20(address(PAW)).safeTransferFrom(
                address(_msgSender()),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
            pool.shares = pool.shares.add(_amount);
            user.share = user.share.add(_amount);

            if (user.bubbleRate > 0) {
                user.share = user.share.add(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
                pool.shares = pool.shares.add(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
            }
        }
        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );

        bean.mint(_for, _amount);

        emit Deposit(_msgSender(), _for, address(PAW), _amount);
    }

    /// @dev Withdraw PAW
    /// @param _amount The amount to be withdrawn
    function withdrawPAW(address _for, uint256 _amount)
        external
        override
        nonReentrant
    {
        PoolInfo storage pool = poolInfo[address(PAW)];
        UserInfo storage user = userInfo[address(PAW)][_for];

        require(
            user.fundedBy == _msgSender(),
            "MasterPAW::withdrawPAW::only funder"
        );
        require(user.amount >= _amount, "MasterPAW::withdrawPAW::not good");

        uint256 lastRewardBlock = pool.lastRewardBlock;
        updatePool(address(PAW));
        _harvest(_for, address(PAW), lastRewardBlock);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            IERC20(address(PAW)).safeTransfer(address(_msgSender()), _amount);

            pool.shares = pool.shares.sub(_amount);
            user.share = user.share.sub(_amount);

            if (user.bubbleRate > 0) {
                user.share = user.share.sub(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
                pool.shares = pool.shares.sub(
                    _amount.mul(user.bubbleRate).div(1e4)
                );
            }
        }
        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );
        if (user.amount == 0) user.fundedBy = address(0);

        bean.burn(_for, _amount);

        emit Withdraw(_msgSender(), _for, address(PAW), user.amount);
    }

    /// @dev Harvest PAW earned from a specific pool.
    /// @param _stakeToken The pool's stake token
    function harvest(address _for, address _stakeToken)
        external
        override
        nonReentrant
    {
        PoolInfo storage pool = poolInfo[_stakeToken];
        UserInfo storage user = userInfo[_stakeToken][_for];

        uint256 lastRewardBlock = pool.lastRewardBlock;
        updatePool(_stakeToken);
        _harvest(_for, _stakeToken, lastRewardBlock);
        user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
        user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
            1e12
        );
    }

    /// @dev Harvest PAW earned from pools.
    /// @param _stakeTokens The list of pool's stake token to be harvested
    function harvest(address _for, address[] calldata _stakeTokens)
        external
        override
        nonReentrant
    {
        for (uint256 i = 0; i < _stakeTokens.length; i++) {
            PoolInfo storage pool = poolInfo[_stakeTokens[i]];
            UserInfo storage user = userInfo[_stakeTokens[i]][_for];
            uint256 lastRewardBlock = pool.lastRewardBlock;
            updatePool(_stakeTokens[i]);
            _harvest(_for, _stakeTokens[i], lastRewardBlock);
            user.rewardDebt = user.share.mul(pool.accPAWPerShare).div(1e12);
            user.bonusDebt = user.share.mul(pool.accPAWPerShareTilBonusEnd).div(
                1e12
            );
        }
    }

    /// @dev Internal function to harvest PAW
    /// @param _for The beneficiary address
    /// @param _stakeToken The pool's stake token
    function _harvest(
        address _for,
        address _stakeToken,
        uint256
    ) internal {
        PoolInfo memory pool = poolInfo[_stakeToken];
        UserInfo memory user = userInfo[_stakeToken][_for];
        require(
            user.fundedBy == _msgSender(),
            "MasterPAW::_harvest::only funder"
        );
        require(user.share > 0, "MasterPAW::_harvest::nothing to harvest");

        uint256 pending = user.share.mul(pool.accPAWPerShare).div(1e12).sub(
            user.rewardDebt
        );
        //pool share -= user.amount * bublleRate
        uint256 poolshareWithoutBubble = pool.shares.sub(
            user.amount.mul(user.bubbleRate).div(1e4)
        );

        //noBubblePending = pending * user.amount / user.share * pool.share / pool.shareWithoutBubble
        uint256 noBubblePending = pending
            .mul(user.amount)
            .div(user.share)
            .mul(pool.shares)
            .div(poolshareWithoutBubble);

        if (
            stakeTokenCallerContracts[_stakeToken].has(_msgSender()) &&
            user.bubbleRate > 0
        ) {
            //bubble reward has a limit
            pending = MathUpgradeable.min(
                pending,
                IMasterPAWCallback(_msgSender()).bubbleRewardLimit(
                    _stakeToken,
                    _for,
                    pending,
                    noBubblePending
                )
            );
        }
        require(
            pending <= PAW.balanceOf(address(bean)),
            "MasterPAW::_harvest::wait what.. not enough PAW"
        );
        uint256 bonus = user
            .share
            .mul(pool.accPAWPerShareTilBonusEnd)
            .div(1e12)
            .sub(user.bonusDebt);
        bean.safePAWTransfer(_for, pending);
        if (
            stakeTokenCallerContracts[_stakeToken].has(_msgSender()) &&
            user.bubbleRate > 0
        ) {
            //record extra reward
            _MasterPAWCallee(
                _msgSender(),
                _stakeToken,
                _for,
                pending.sub(noBubblePending)
            );
        }
        PAW.lock(_for, bonus.mul(bonusLockUpBps).div(10000));

        emit Harvest(_msgSender(), _for, _stakeToken, pending);
    }

    /// @dev Observer function for those contract implementing onBeforeLock, execute an onBeforelock statement
    /// @param _caller that perhaps implement an onBeforeLock observing function
    /// @param _stakeToken parameter for sending a staoke token
    /// @param _for the user this callback will be used
    /// @param _extraReward extra reward
    function _MasterPAWCallee(
        address _caller,
        address _stakeToken,
        address _for,
        uint256 _extraReward
    ) internal {
        if (!_caller.isContract()) {
            return;
        }
        (bool success, ) = _caller.call(
            abi.encodeWithSelector(
                IMasterPAWCallback.masterPAWCall.selector,
                _stakeToken,
                _for,
                _extraReward
            )
        );
        require(
            success,
            "MasterPAW::_MasterPAWCallee:: failed to execute MasterPAWCall"
        );
    }

    /// @dev Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param _for if the msg sender is a funder, can emergency withdraw a fundee
    /// @param _stakeToken The pool's stake token
    function emergencyWithdraw(address _for, address _stakeToken)
        external
        override
        nonReentrant
    {
        UserInfo storage user = userInfo[_stakeToken][_for];
        PoolInfo storage pool = poolInfo[_stakeToken];
        require(
            user.fundedBy == _msgSender(),
            "MasterPAW::emergencyWithdraw::only funder"
        );
        IERC20(_stakeToken).safeTransfer(address(_for), user.amount);

        emit EmergencyWithdraw(_for, _stakeToken, user.amount);

        // Burn BEAN if user emergencyWithdraw PAW
        if (_stakeToken == address(PAW)) {
            bean.burn(_for, user.amount);
        }

        // Reset user info
        pool.shares = pool.shares.sub(user.share);
        user.amount = 0;
        user.share = 0;
        user.rewardDebt = 0;
        user.bonusDebt = 0;
        user.fundedBy = address(0);
    }

    /// @dev what is a proportion of onlyBonusMultiplier in a form of BPS comparing to the total multiplier
    /// @param _lastRewardBlock The last block that rewards have been paid
    /// @param _currentBlock The current block
    function _getBonusMultiplierProportionBps(
        uint256 _lastRewardBlock,
        uint256 _currentBlock
    ) internal view returns (uint256) {
        if (_currentBlock <= bonusEndBlock) {
            return 1e4;
        }
        if (_lastRewardBlock >= bonusEndBlock) {
            return 0;
        }
        // This is the case where bonusEndBlock is in the middle of _lastRewardBlock and _currentBlock block.
        uint256 onlyBonusMultiplier = bonusEndBlock.sub(_lastRewardBlock).mul(
            bonusMultiplier
        );
        uint256 totalMultiplier = onlyBonusMultiplier.add(
            _currentBlock.sub(bonusEndBlock)
        );
        return onlyBonusMultiplier.mul(1e4).div(totalMultiplier);
    }

    /// @dev This is a function for mining an extra amount of PAW, should be called only by stake token caller contract (boosting purposed)
    /// @param _stakeToken a stake token address for validating a msg sender
    /// @param _amount amount to be minted
    function mintExtraReward(
        address _stakeToken,
        address _to,
        uint256 _amount,
        uint256 _lastRewardBlock
    ) external override onlyStakeTokenCallerContract(_stakeToken) {
        uint256 multiplierBps = _getBonusMultiplierProportionBps(
            _lastRewardBlock,
            block.number
        );
        uint256 toBeLockedNum = _amount.mul(multiplierBps).mul(bonusLockUpBps);

        // mint & lock(if any) an extra reward
        PAW.mint(_to, _amount);
        PAW.lock(_to, toBeLockedNum.div(1e8));
        PAW.mint(devAddr, _amount.mul(devFeeBps).div(1e4));
        PAW.lock(devAddr, (toBeLockedNum.mul(devFeeBps)).div(1e12));

        emit MintExtraReward(_msgSender(), _stakeToken, _to, _amount);
    }
}
