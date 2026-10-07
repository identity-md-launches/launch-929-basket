// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskMath} from "./BaskMath.sol";

/// @notice Basket Protocol index vault for Stock Tokens on Robinhood Chain (4663).
contract BaskVault {
    string public constant name = "Basket";
    string public constant symbol = "BASK";
    uint8 public constant decimals = 18;
    address public constant STOCK_FACTORY = 0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046;
    uint256 public constant MAX_ASSETS = 64;
    uint256 public constant MAX_NAV_CAP = 10_000_000_000e18;
    uint256 public constant LOCKED_SHARES = 1e15;
    uint256 public constant PROPOSAL_DELAY = 7 days;
    uint256 public constant PROPOSAL_LIFETIME = 7 days;
    uint256 public constant PRICE_AGE = 26 hours;

    enum Kind {
        List,
        Feed,
        Band,
        Reopen,
        Retire,
        Guardian,
        NavCap
    }
    enum ProposalState {
        Missing,
        Waiting,
        Ready,
        Expired,
        Cancelled,
        Executed,
        Voided
    }
    enum Reason {
        Ok,
        Genesis,
        WarmingUp,
        Paused,
        Unlisted,
        Retired,
        Closed,
        BalanceUnreadable,
        OwedUnderfunded,
        MarketClosed,
        TooFewFreshFeeds,
        FeedUnreadable,
        NonPositivePrice,
        OutsideBand,
        FuturePrice,
        StalePrice,
        OracleUnreadable,
        OraclePaused,
        Deficit,
        ZeroNAV
    }

    struct Asset {
        address token;
        address feed;
        bool open;
        bool retired;
        uint256 minAnswer;
        uint256 maxAnswer;
    }

    struct Proposal {
        Kind kind;
        address token;
        address target;
        uint256 value;
        uint256 createdAt;
        uint256 epoch;
        bool cancelled;
        bool executed;
    }

    struct Loss {
        uint256 amount;
        uint256 since;
    }

    struct AssetView {
        address token;
        address feed;
        int256 answer;
        uint256 updatedAt;
        uint256 minAnswer;
        uint256 maxAnswer;
        bool open;
        bool retired;
        uint256 managed;
        bool short;
        uint256 totalOwed;
        bool balanceReadable;
        bool feedReadable;
    }

    struct Snapshot {
        Reason reason;
        address fault;
        uint256 nav;
        uint256 price;
        uint256 balance;
    }

    error Unauthorized();
    error Reentrancy();
    error InvalidAddress();
    error InvalidAsset(address token);
    error InvalidFeed(address feed);
    error AssetLimit();
    error LengthMismatch();
    error InvalidState();
    error InvalidProposal(uint256 id);
    error ChangeTooSoon();
    error DeadlineExpired();
    error DepositUnavailable(Reason reason, address asset);
    error Slippage();
    error InvalidAmount();
    error CapExceeded();
    error BucketExceeded();
    error TransferFailed(address token);
    error InsufficientBalance();
    error InsufficientAllowance();
    error BalanceUnreadable(address token);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event GuardianChanged(address indexed guardian);
    event FeeRecipientSet(address indexed recipient);
    event DepositsPaused(bool paused);
    event GenesisFinalized(uint256 depositsOpenAt);
    event AssetListed(address indexed token, address indexed feed, uint256 minAnswer, uint256 maxAnswer);
    event AssetClosed(address indexed token);
    event AssetReopened(address indexed token);
    event AssetRetired(address indexed token);
    event FeedChanged(address indexed token, address indexed feed);
    event BandChanged(address indexed token, uint256 minAnswer, uint256 maxAnswer);
    event NavCapChanged(uint256 cap);
    event ProposalCreated(uint256 indexed id, Kind kind, address token, address target, uint256 value);
    event ProposalCancelled(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event Deposit(
        address indexed caller,
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 fee
    );
    event Redeem(address indexed caller, uint256 shares, uint256 fee);
    event LegPaid(address indexed token, address indexed to, uint256 amount);
    event LegOwed(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed token, address indexed to, uint256 amount);
    event DeficitFlagged(address indexed token, uint256 amount, uint256 since);
    event LossRecognized(address indexed token, uint256 amount);
    event DeficitCleared(address indexed token);

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    bool public depositsPaused;
    bool public genesisFinalized;
    uint256 public depositsOpenAt;
    uint256 public NAV_CAP = 1_000_000e18;
    uint256 public bucket;
    uint256 public bucketUpdatedAt;
    uint256 public nextAssetChangeAt;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Asset[] public assets;
    mapping(address => uint256) public assetIndexPlusOne;
    mapping(address => uint256) public managed;
    mapping(address => mapping(address => uint256)) public owed;
    mapping(address => uint256) public totalOwed;
    mapping(address => Loss) public deficits;
    mapping(address => uint256) public closeEpoch;
    uint256 public capEpoch;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    uint256 private entered;

    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0) || owner_ == guardian_) revert InvalidAddress();
        owner = owner_;
        guardian = guardian_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
    }

    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyOperator() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0) || from == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transferOwnership(address next) external nonReentrant onlyOwner {
        if (next == address(0) || next == guardian) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert Unauthorized();
        if (msg.sender == guardian) revert InvalidAddress();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    function setFeeRecipient(address recipient) external nonReentrant onlyOwner {
        if (feeRecipient != address(0)) revert InvalidState();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function pauseDeposits() external nonReentrant onlyOperator {
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    function unpauseDeposits() external nonReentrant onlyOwner {
        depositsPaused = false;
        emit DepositsPaused(false);
    }

    function closeAsset(address token) external nonReentrant onlyOperator {
        Asset storage a = _asset(token);
        a.open = false;
        ++closeEpoch[token];
        emit AssetClosed(token);
    }

    function lowerNavCap(uint256 cap) external nonReentrant onlyOwner {
        if (cap >= NAV_CAP) revert InvalidAmount();
        NAV_CAP = cap;
        ++capEpoch;
        emit NavCapChanged(cap);
    }

    function finalizeGenesis() external nonReentrant onlyOwner {
        if (genesisFinalized || assets.length < 3) revert InvalidState();
        genesisFinalized = true;
        depositsOpenAt = block.timestamp + 72 hours;
        emit GenesisFinalized(depositsOpenAt);
    }

    function proposeAsset(address token, address feed) external nonReentrant onlyOwner returns (uint256) {
        return _proposeAsset(token, feed);
    }

    function proposeAssets(address[] calldata tokens, address[] calldata feeds)
        external
        nonReentrant
        onlyOwner
        returns (uint256[] memory ids)
    {
        if (tokens.length != feeds.length) revert LengthMismatch();
        ids = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            ids[i] = _proposeAsset(tokens[i], feeds[i]);
        }
    }

    function _proposeAsset(address token, address feed) internal returns (uint256) {
        uint256 answer = _checkListing(token, feed);
        if (!genesisFinalized) {
            _list(token, feed, answer);
            return 0;
        }
        return _propose(Kind.List, token, feed, 0, 0);
    }

    function proposeFeed(address token, address feed) external nonReentrant onlyOwner returns (uint256) {
        Asset storage a = _activeAsset(token);
        _checkReplacement(a, feed);
        return _propose(Kind.Feed, token, feed, 0, 0);
    }

    function proposeBand(address token) external nonReentrant onlyOwner returns (uint256) {
        _activeAsset(token);
        return _propose(Kind.Band, token, address(0), 0, 0);
    }

    function proposeReopen(address token) external nonReentrant onlyOwner returns (uint256) {
        _activeAsset(token);
        return _propose(Kind.Reopen, token, address(0), 0, closeEpoch[token]);
    }

    function proposeRetire(address token) external nonReentrant onlyOwner returns (uint256) {
        if (_activeAsset(token).open) revert InvalidState();
        return _propose(Kind.Retire, token, address(0), 0, 0);
    }

    function proposeGuardian(address next) external nonReentrant onlyOwner returns (uint256) {
        _checkGuardian(next);
        return _propose(Kind.Guardian, address(0), next, 0, 0);
    }

    function proposeNavCap(uint256 cap) external nonReentrant onlyOwner returns (uint256) {
        _checkRaise(cap);
        return _propose(Kind.NavCap, address(0), address(0), cap, capEpoch);
    }

    function _propose(Kind kind, address token, address target, uint256 value, uint256 epoch)
        internal
        returns (uint256 id)
    {
        id = ++proposalCount;
        proposals[id] = Proposal(kind, token, target, value, block.timestamp, epoch, false, false);
        emit ProposalCreated(id, kind, token, target, value);
    }

    function cancelProposal(uint256 id) external nonReentrant onlyOperator {
        ProposalState state = proposalState(id);
        if (state != ProposalState.Waiting && state != ProposalState.Ready) revert InvalidProposal(id);
        Proposal storage p = proposals[id];
        if (msg.sender != owner && p.kind == Kind.Guardian) revert Unauthorized();
        p.cancelled = true;
        emit ProposalCancelled(id);
    }

    function executeProposal(uint256 id) external nonReentrant {
        if (proposalState(id) != ProposalState.Ready) revert InvalidProposal(id);
        Proposal storage p = proposals[id];
        p.executed = true;
        if (p.kind == Kind.List || p.kind == Kind.Feed) {
            if (block.timestamp < nextAssetChangeAt) revert ChangeTooSoon();
            nextAssetChangeAt = block.timestamp + 24 hours;
        }
        if (p.kind == Kind.List) {
            _list(p.token, p.target, _checkListing(p.token, p.target));
        } else if (p.kind == Kind.Feed) {
            Asset storage a = _activeAsset(p.token);
            _checkReplacement(a, p.target);
            a.feed = p.target;
            emit FeedChanged(p.token, p.target);
        } else if (p.kind == Kind.Band) {
            Asset storage a = _activeAsset(p.token);
            (bool ok, int256 answer, uint256 updated) = _readFeed(a.feed);
            if (!ok || answer <= 0 || updated > block.timestamp || block.timestamp - updated >= PRICE_AGE) {
                revert InvalidFeed(a.feed);
            }
            (a.minAnswer, a.maxAnswer) = _band(uint256(answer));
            emit BandChanged(p.token, a.minAnswer, a.maxAnswer);
        } else if (p.kind == Kind.Reopen) {
            _activeAsset(p.token).open = true;
            emit AssetReopened(p.token);
        } else if (p.kind == Kind.Retire) {
            Asset storage a = _activeAsset(p.token);
            if (a.open) revert InvalidState();
            a.retired = true;
            emit AssetRetired(p.token);
        } else if (p.kind == Kind.Guardian) {
            _checkGuardian(p.target);
            guardian = p.target;
            emit GuardianChanged(p.target);
        } else {
            _checkRaise(p.value);
            NAV_CAP = p.value;
            emit NavCapChanged(p.value);
        }
        emit ProposalExecuted(id);
    }

    function proposalState(uint256 id) public view returns (ProposalState) {
        if (id == 0 || id > proposalCount) return ProposalState.Missing;
        Proposal storage p = proposals[id];
        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        uint256 index = assetIndexPlusOne[p.token];
        if (index != 0 && assets[index - 1].retired) return ProposalState.Voided;
        if (p.kind == Kind.Reopen && p.epoch != closeEpoch[p.token]) return ProposalState.Voided;
        if (p.kind == Kind.NavCap && p.epoch != capEpoch) return ProposalState.Voided;
        if (block.timestamp < p.createdAt + PROPOSAL_DELAY) return ProposalState.Waiting;
        if (block.timestamp >= p.createdAt + PROPOSAL_DELAY + PROPOSAL_LIFETIME) {
            return ProposalState.Expired;
        }
        return ProposalState.Ready;
    }

    /// @notice Enumerate IDs in [start, start+count); return only waiting/ready proposals.
    function pendingProposals(uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        if (start == 0) start = 1;
        if (start > proposalCount) return new uint256[](0);
        uint256 remaining = proposalCount - start + 1;
        if (count > remaining) count = remaining;
        ids = new uint256[](count);
        uint256 n;
        for (uint256 i; i < count; ++i) {
            ProposalState state = proposalState(start + i);
            if (state == ProposalState.Waiting || state == ProposalState.Ready) ids[n++] = start + i;
        }
        assembly ("memory-safe") { mstore(ids, n) }
    }

    function _checkGuardian(address next) internal view {
        if (next == address(0) || next == owner) revert InvalidAddress();
    }

    function _checkRaise(uint256 cap) internal view {
        if (cap <= NAV_CAP || cap > MAX_NAV_CAP) revert InvalidAmount();
    }

    function _asset(address token) internal view returns (Asset storage a) {
        uint256 index = assetIndexPlusOne[token];
        if (index == 0) revert InvalidAsset(token);
        return assets[index - 1];
    }

    function _activeAsset(address token) internal view returns (Asset storage a) {
        a = _asset(token);
        if (a.retired) revert InvalidAsset(token);
    }

    function _checkListing(address token, address feed) internal view returns (uint256 answer) {
        if (assetIndexPlusOne[token] != 0) revert InvalidAsset(token);
        if (assets.length == MAX_ASSETS) revert AssetLimit();
        (bool ok, uint256 word) = _word(token, abi.encodeWithSignature("decimals()"), gasleft());
        if (!ok || word != 18) revert InvalidAsset(token);
        (ok, word) = _word(token, abi.encodeWithSignature("uid()"), gasleft());
        if (!ok) revert InvalidAsset(token);
        (ok, word) =
            _word(STOCK_FACTORY, abi.encodeWithSignature("tokenAddress(bytes32)", bytes32(word)), gasleft());
        if (!ok || word != uint256(uint160(token))) revert InvalidAsset(token);
        answer = _checkFeed(token, feed);
        _band(answer);
    }

    function _checkFeed(address token, address feed) internal view returns (uint256) {
        (bool ok, uint256 word) = _word(feed, abi.encodeWithSignature("decimals()"), gasleft());
        if (!ok || word != 8) revert InvalidFeed(feed);
        (ok, word) = _word(feed, abi.encodeWithSignature("aggregator()"), gasleft());
        if (!ok || word == 0 || word > type(uint160).max) revert InvalidFeed(feed);
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            if (!a.retired && a.token != token && a.feed == feed) revert InvalidFeed(feed);
        }
        int256 answer;
        (ok, answer,) = _readFeed(feed);
        if (!ok || answer <= 0) revert InvalidFeed(feed);
        return uint256(answer);
    }

    function _checkReplacement(Asset storage a, address feed) internal view {
        uint256 answer = _checkFeed(a.token, feed);
        if (answer < a.minAnswer || answer > a.maxAnswer) revert InvalidFeed(feed);
    }

    function _band(uint256 answer) internal pure returns (uint256, uint256) {
        if (answer > type(uint256).max / 4) revert InvalidAmount();
        return (answer / 4, answer * 4);
    }

    function _list(address token, address feed, uint256 answer) internal {
        (uint256 low, uint256 high) = _band(answer);
        assets.push(Asset(token, feed, true, false, low, high));
        assetIndexPlusOne[token] = assets.length;
        emit AssetListed(token, feed, low, high);
    }

    function deposit(address token, uint256 amount, address receiver, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        Snapshot memory s = _snapshot(token);
        _requireAvailable(s);
        uint256 value = BaskMath.mulDiv(amount, s.price, 1e8);
        uint256 fee;
        uint256 locked;
        (shares, fee, locked) = _depositQuote(value, s.nav);
        if (shares < minSharesOut) revert Slippage();
        uint256 nav2 = s.nav + value;
        if (nav2 > NAV_CAP) revert CapExceeded();
        uint256 nextBucket = decayedBucket() + value;
        uint256 limit = nav2 / 4;
        if (limit < 100_000e18) limit = 100_000e18;
        if (nextBucket > limit) revert BucketExceeded();

        _tokenCall(
            token,
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", msg.sender, address(this), amount
            )
        );
        (bool ok, uint256 afterBalance) = _balance(token);
        if (!ok || afterBalance < s.balance || afterBalance - s.balance != amount) {
            revert TransferFailed(token);
        }
        managed[token] += amount;
        bucket = nextBucket;
        bucketUpdatedAt = block.timestamp;
        for (uint256 i; i < assets.length; ++i) {
            address t = assets[i].token;
            if (!assets[i].retired && deficits[t].amount != 0) {
                delete deficits[t];
                emit DeficitCleared(t);
            }
        }
        if (locked != 0) _mint(address(0xdEaD), locked);
        _mint(receiver, shares);
        if (feeRecipient != address(0)) _mint(feeRecipient, fee);
        emit Deposit(msg.sender, receiver, token, amount, shares, fee);
    }

    function _depositQuote(uint256 value, uint256 nav)
        internal
        view
        returns (uint256 shares, uint256 fee, uint256 locked)
    {
        uint256 gross = totalSupply == 0 ? value : BaskMath.mulDiv(value, totalSupply, nav);
        fee = _fee(gross);
        shares = gross - fee;
        if (totalSupply == 0) {
            locked = LOCKED_SHARES;
            if (shares <= locked) revert InvalidAmount();
            shares -= locked;
        }
        if (shares == 0) revert InvalidAmount();
    }

    function decayedBucket() public view returns (uint256) {
        uint256 elapsed = block.timestamp - bucketUpdatedAt;
        if (elapsed >= 1 days) return 0;
        return bucket - BaskMath.mulDiv(bucket, elapsed, 1 days);
    }

    function redeem(uint256 shares, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (balanceOf[msg.sender] < shares) revert InsufficientBalance();
        uint256 supply = totalSupply;
        uint256 fee = _fee(shares);
        uint256 net = shares - fee;
        if (feeRecipient == address(0)) {
            _burn(msg.sender, shares);
        } else {
            _transfer(msg.sender, feeRecipient, fee);
            _burn(msg.sender, net);
        }
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i].token;
            uint256 leg = _leg(token, net, supply);
            if (i < minAmountsOut.length && leg < minAmountsOut[i]) revert Slippage();
            amounts[i] = leg;
            managed[token] -= leg;
            if (leg != 0 && !_tryPay(token, msg.sender, leg)) {
                owed[msg.sender][token] += leg;
                totalOwed[token] += leg;
                emit LegOwed(msg.sender, token, leg);
            }
        }
        emit Redeem(msg.sender, shares, fee);
    }

    function _leg(address token, uint256 net, uint256 supply) internal view returns (uint256) {
        if (net == 0) return 0;
        (, uint256 available) = _available(token);
        uint256 amount = managed[token];
        if (available < amount) amount = available;
        return BaskMath.mulDiv(amount, net, supply);
    }

    function _tryPay(address token, address to, uint256 amount) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(this.payLeg, (token, to, amount));
        // No returndata is copied, even when a hostile token returns/reverts with a huge payload.
        assembly ("memory-safe") { ok := call(250000, address(), 0, add(data, 32), mload(data), 0, 0) }
    }

    /// @dev Atomic payout frame. Only entered by redeem/claim while their guard is held.
    function payLeg(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        (bool ok, uint256 beforeBalance) = _balance(token);
        if (!ok) revert TransferFailed(token);
        _tokenCall(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        uint256 afterBalance;
        (ok, afterBalance) = _balance(token);
        if (!ok || beforeBalance < afterBalance || beforeBalance - afterBalance != amount) {
            revert TransferFailed(token);
        }
        emit LegPaid(token, to, amount);
    }

    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidAddress();
        (bool ok, uint256 available) = _balance(token);
        if (!ok) revert BalanceUnreadable(token);
        amount = owed[msg.sender][token];
        if (available < amount) amount = available;
        owed[msg.sender][token] -= amount;
        totalOwed[token] -= amount;
        if (amount != 0) this.payLeg(token, to, amount);
        emit Claimed(msg.sender, token, to, amount);
    }

    function flagDeficit(address token) external nonReentrant {
        _asset(token);
        uint256 shortfall = _shortfall(token);
        Loss storage loss = deficits[token];
        if (shortfall > loss.amount) {
            loss.amount = shortfall;
            loss.since = block.timestamp;
        }
        emit DeficitFlagged(token, loss.amount, loss.since);
    }

    function recognizeLoss(address token) external nonReentrant {
        _asset(token);
        Loss memory loss = deficits[token];
        if (loss.amount == 0 || block.timestamp < loss.since + 7 days) revert InvalidState();
        uint256 amount = _shortfall(token);
        if (amount > loss.amount) amount = loss.amount;
        managed[token] -= amount;
        delete deficits[token];
        emit LossRecognized(token, amount);
    }

    function _shortfall(address token) internal view returns (uint256) {
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert BalanceUnreadable(token);
        return available < managed[token] ? managed[token] - available : 0;
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount / 200 + (amount % 200 == 0 ? 0 : 1);
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function allAssets() external view returns (AssetView[] memory result) {
        result = new AssetView[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            (bool feedOk, int256 answer, uint256 updatedAt) = _readFeed(a.feed);
            (bool balanceOk, uint256 available) = _available(a.token);
            result[i] = AssetView(
                a.token,
                a.feed,
                answer,
                updatedAt,
                a.minAnswer,
                a.maxAnswer,
                a.open,
                a.retired,
                managed[a.token],
                available < managed[a.token],
                totalOwed[a.token],
                balanceOk,
                feedOk
            );
        }
    }

    function depositStatus(address token) external view returns (Reason reason, address asset) {
        Snapshot memory s = _snapshot(token);
        return (s.reason, s.fault);
    }

    function previewDeposit(address token, uint256 amount)
        external
        view
        returns (uint256 shares, uint256 fee, uint256 locked)
    {
        Snapshot memory s = _snapshot(token);
        _requireAvailable(s);
        return _depositQuote(BaskMath.mulDiv(amount, s.price, 1e8), s.nav);
    }

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts, uint256 fee) {
        if (shares > totalSupply) revert InvalidAmount();
        fee = _fee(shares);
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            amounts[i] = _leg(assets[i].token, shares - fee, totalSupply);
        }
    }

    function _requireAvailable(Snapshot memory s) internal pure {
        if (s.reason != Reason.Ok) revert DepositUnavailable(s.reason, s.fault);
    }

    function _fail(Snapshot memory s, Reason reason, address token) internal pure returns (Snapshot memory) {
        s.reason = reason;
        s.fault = token;
        return s;
    }

    function _snapshot(address token) internal view returns (Snapshot memory s) {
        if (!genesisFinalized) return _fail(s, Reason.Genesis, address(0));
        if (block.timestamp < depositsOpenAt) return _fail(s, Reason.WarmingUp, address(0));
        if (depositsPaused) return _fail(s, Reason.Paused, address(0));
        uint256 index = assetIndexPlusOne[token];
        if (index == 0) return _fail(s, Reason.Unlisted, token);
        Asset storage target = assets[index - 1];
        if (target.retired) return _fail(s, Reason.Retired, token);
        if (!target.open) return _fail(s, Reason.Closed, token);
        (bool ok, uint256 targetBalance) = _balance(token);
        if (!ok) return _fail(s, Reason.BalanceUnreadable, token);
        if (targetBalance < totalOwed[token]) return _fail(s, Reason.OwedUnderfunded, token);
        s.balance = targetBalance;
        uint256 day = (block.timestamp / 1 days + 4) % 7;
        uint256 secondsToday = block.timestamp % 1 days;
        if (day == 0 || day == 6 || secondsToday < 55800 || secondsToday >= 70200) {
            return _fail(s, Reason.MarketClosed, address(0));
        }
        uint256 fresh;
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            if (a.retired) continue;
            (bool read, int256 answer, uint256 updated) = _readFeed(a.feed);
            if (read && updated <= block.timestamp && block.timestamp - updated <= 4 hours) ++fresh;
            // Price checks apply only to the input token and managed positions.
            if (a.token == token || managed[a.token] != 0) {
                Reason reason = _priceStatus(a, read, answer, updated);
                if (reason != Reason.Ok) return _fail(s, reason, a.token);
                if (a.token == token) s.price = uint256(answer);
                s.nav += BaskMath.mulDiv(managed[a.token], uint256(answer), 1e8);
            }
            (bool readable, uint256 available) = _available(a.token);
            if (!readable) return _fail(s, Reason.BalanceUnreadable, a.token);
            if (available < managed[a.token]) return _fail(s, Reason.Deficit, a.token);
        }
        if (fresh < 3) return _fail(s, Reason.TooFewFreshFeeds, address(0));
        if (totalSupply != 0 && s.nav == 0) return _fail(s, Reason.ZeroNAV, address(0));
    }

    function _priceStatus(Asset storage a, bool read, int256 answer, uint256 updated)
        internal
        view
        returns (Reason)
    {
        if (!read) return Reason.FeedUnreadable;
        if (answer <= 0) return Reason.NonPositivePrice;
        if (uint256(answer) < a.minAnswer || uint256(answer) > a.maxAnswer) return Reason.OutsideBand;
        if (updated > block.timestamp) return Reason.FuturePrice;
        if (block.timestamp - updated > PRICE_AGE) return Reason.StalePrice;
        (bool ok, uint256 paused) = _word(a.token, abi.encodeWithSignature("oraclePaused()"), 100_000);
        if (!ok || paused > 1) return Reason.OracleUnreadable;
        if (paused != 0) return Reason.OraclePaused;
        return Reason.Ok;
    }

    function _available(address token) internal view returns (bool readable, uint256 available) {
        (readable, available) = _balance(token);
        if (!readable) return (false, managed[token]);
        uint256 reserved = totalOwed[token];
        available = available > reserved ? available - reserved : 0;
    }

    function _balance(address token) internal view returns (bool, uint256) {
        return _word(token, abi.encodeWithSignature("balanceOf(address)", address(this)), 50_000);
    }

    function _word(address target, bytes memory data, uint256 gasLimit)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            ok := staticcall(gasLimit, target, add(data, 32), mload(data), ptr, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(ptr)
        }
    }

    function _readFeed(address feed) internal view returns (bool ok, int256 answer, uint256 updated) {
        bytes memory data = abi.encodeWithSignature("latestRoundData()");
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            ok := staticcall(100000, feed, add(data, 32), mload(data), ptr, 160)
            ok := and(ok, eq(returndatasize(), 160))
            answer := mload(add(ptr, 32))
            updated := mload(add(ptr, 96))
        }
        if (!ok) return (false, 0, 0);
    }

    function _tokenCall(address token, bytes memory data) internal {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            ok := call(gas(), token, 0, add(data, 32), mload(data), ptr, 32)
            ok := and(ok, or(iszero(returndatasize()), and(eq(returndatasize(), 32), eq(mload(ptr), 1))))
        }
        if (!ok) revert TransferFailed(token);
    }
}
