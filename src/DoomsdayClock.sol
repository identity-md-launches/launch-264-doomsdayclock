// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DoomsdayClock
/// @notice A last-buyer timer game paid in DOOM, played in rounds.
///
/// Rules
/// - A round opens with its first key purchase, which sets `end = block.timestamp + 1 hour`
///   before the purchased keys add their time.
/// - `buyKeys(n, maxCost)` buys `1 <= n <= 100` keys. Key `k` of a round (k from 0) costs
///   `price_0 = 1e18` and `price_k = ceil(price_(k-1) * 1001 / 1000)`. The total must be
///   `<= maxCost`.
/// - Every key adds 30 seconds: `end = min(end + 30 * n, block.timestamp + 24 hours)`.
/// - The buyer becomes `lastBuyer`. The pot is every DOOM paid for keys in the round plus the
///   carry folded in from the previous round when the round opened.
/// - Once `block.timestamp >= end`, anyone may `settle()`; the next `buyKeys` settles first and
///   then opens the following round. 50% of the pot (rounded down) is credited to the last
///   buyer, every key holder may `claimShare(round)` for `floor(pot * 30% / totalKeys)` per key,
///   and the remainder (20% plus rounding dust) becomes the next round's carry.
/// - All payouts are pull-based: credits accumulate in `withdrawable` and `withdraw()` pays them.
///
/// The contract has no owner, admin, pause or upgrade path, no payable function and no
/// receive/fallback, so it never holds ETH. It holds no DOOM at deployment.
///
/// Known property: the last buyer is decided by transaction ordering and block timestamps.
/// Block stuffing near `end` is a known strategy. This is a Sepolia test game with no real value.
contract DoomsdayClock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Maximum keys per purchase.
    uint256 public constant MAX_KEYS_PER_BUY = 100;
    /// @notice Price of key 0 in every round (1 DOOM).
    uint256 public constant BASE_PRICE = 1e18;
    /// @notice Price growth numerator: each key costs ceil(previous * 1001 / 1000).
    uint256 public constant PRICE_NUM = 1001;
    /// @notice Price growth denominator.
    uint256 public constant PRICE_DEN = 1000;
    /// @notice Base timer set when a round opens.
    uint256 public constant ROUND_DURATION = 1 hours;
    /// @notice Time added per key.
    uint256 public constant TIME_PER_KEY = 30 seconds;
    /// @notice `end` can never be more than this far in the future.
    uint256 public constant MAX_EXTENSION = 24 hours;
    /// @notice Share of the pot credited to the last buyer, in basis points.
    uint256 public constant WINNER_BPS = 5000;
    /// @notice Share of the pot split equally per key, in basis points.
    uint256 public constant SHARE_BPS = 3000;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    // ------------------------------------------------------------------
    // Types, storage, events, errors
    // ------------------------------------------------------------------

    struct Round {
        /// @dev 0 until the first key of the round is bought.
        uint256 end;
        /// @dev DOOM paid for keys in this round plus the carry folded in at opening.
        uint256 pot;
        /// @dev Keys sold in this round.
        uint256 totalKeys;
        /// @dev Price of the next key; BASE_PRICE once the round is open.
        uint256 nextPrice;
        /// @dev Per-key share fixed at settlement.
        uint256 perKey;
        /// @dev Most recent buyer.
        address lastBuyer;
        /// @dev True once settled; shares become claimable.
        bool settled;
    }

    IERC20 private immutable _token;

    /// @dev Current round id. Round ids start at 1. After settlement the id advances to a
    /// round that has not opened yet (`end == 0`).
    uint256 private _round = 1;
    /// @dev DOOM carried from the last settled round, not yet folded into a pot.
    uint256 private _carry;

    mapping(uint256 round => Round) private _rounds;
    mapping(uint256 round => mapping(address account => uint256)) private _keys;
    mapping(uint256 round => mapping(address account => bool)) private _claimed;
    mapping(address account => uint256) private _withdrawable;

    event KeysBought(uint256 indexed round, address indexed buyer, uint256 n, uint256 cost, uint256 end);
    event Settled(uint256 indexed round, address indexed lastBuyer, uint256 prize, uint256 perKey, uint256 carry);
    event ShareClaimed(uint256 indexed round, address indexed account, uint256 keys, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    error ZeroToken();
    error TokenNotContract(address token);
    error InvalidKeyCount(uint256 n);
    error CostExceedsMax(uint256 cost, uint256 maxCost);
    error RoundNotEnded();
    error RoundNotSettled(uint256 round);
    error NoKeys(uint256 round, address account);
    error AlreadyClaimed(uint256 round, address account);
    error NothingToWithdraw();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param token_ The DOOM token address. This is the only constructor argument.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        if (token_.code.length == 0) revert TokenNotContract(token_);
        _token = IERC20(token_);
    }

    // ------------------------------------------------------------------
    // Game actions
    // ------------------------------------------------------------------

    /// @notice Buy `n` keys in the current round for at most `maxCost` DOOM.
    /// @dev If the current round has ended it is settled first and the purchase opens the next
    /// round. The caller must have approved this contract for at least the cost.
    /// @param n Number of keys, 1 to 100.
    /// @param maxCost Slippage guard: the call reverts if the total cost exceeds it.
    /// @return cost The DOOM actually paid.
    function buyKeys(uint256 n, uint256 maxCost) external nonReentrant returns (uint256 cost) {
        if (n == 0 || n > MAX_KEYS_PER_BUY) revert InvalidKeyCount(n);

        uint256 id = _round;
        Round storage r = _rounds[id];

        if (r.end != 0 && block.timestamp >= r.end) {
            _settle(id, r);
            id = _round;
            r = _rounds[id];
        }

        if (r.end == 0) {
            // First key of the round: open it and fold in the carry.
            r.end = block.timestamp + ROUND_DURATION;
            r.nextPrice = BASE_PRICE;
            r.pot = _carry;
            _carry = 0;
        }

        uint256 nextPrice;
        (cost, nextPrice) = _cost(r.nextPrice, n);
        if (cost > maxCost) revert CostExceedsMax(cost, maxCost);

        r.nextPrice = nextPrice;
        r.pot += cost;
        r.totalKeys += n;
        r.lastBuyer = msg.sender;
        _keys[id][msg.sender] += n;

        uint256 newEnd = r.end + TIME_PER_KEY * n;
        uint256 cap = block.timestamp + MAX_EXTENSION;
        if (newEnd > cap) newEnd = cap;
        r.end = newEnd;

        emit KeysBought(id, msg.sender, n, cost, newEnd);

        _token.safeTransferFrom(msg.sender, address(this), cost);
    }

    /// @notice Settle the current round once its timer has expired.
    function settle() external nonReentrant {
        uint256 id = _round;
        Round storage r = _rounds[id];
        if (r.end == 0 || block.timestamp < r.end) revert RoundNotEnded();
        _settle(id, r);
    }

    /// @notice Credit the caller's per-key share of a settled round to their withdrawable balance.
    /// @param id The settled round to claim from.
    /// @return amount The DOOM credited.
    function claimShare(uint256 id) external nonReentrant returns (uint256 amount) {
        Round storage r = _rounds[id];
        if (!r.settled) revert RoundNotSettled(id);
        uint256 keys = _keys[id][msg.sender];
        if (keys == 0) revert NoKeys(id, msg.sender);
        if (_claimed[id][msg.sender]) revert AlreadyClaimed(id, msg.sender);

        _claimed[id][msg.sender] = true;
        amount = keys * r.perKey;
        _withdrawable[msg.sender] += amount;

        emit ShareClaimed(id, msg.sender, keys, amount);
    }

    /// @notice Pay out the caller's credited DOOM.
    /// @return amount The DOOM transferred.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _withdrawable[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        _token.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The DOOM token.
    function token() external view returns (address) {
        return address(_token);
    }

    /// @notice Current round id (starts at 1; advances at settlement).
    function round() external view returns (uint256) {
        return _round;
    }

    /// @notice Timer end of the current round, or 0 if it has not opened.
    function end() external view returns (uint256) {
        return _rounds[_round].end;
    }

    /// @notice Pot of the current round (keys paid plus carry folded in at opening).
    function pot() external view returns (uint256) {
        return _rounds[_round].pot;
    }

    /// @notice DOOM carried from the last settled round and not yet folded into a pot.
    function carry() external view returns (uint256) {
        return _carry;
    }

    /// @notice Last buyer of the current round, or the zero address if it has not opened.
    function lastBuyer() external view returns (address) {
        return _rounds[_round].lastBuyer;
    }

    /// @notice Total cost of the next `n` keys. If the current round has ended or has not opened,
    /// the quote starts from BASE_PRICE because the purchase would open a new round.
    function priceOfNext(uint256 n) external view returns (uint256 cost) {
        if (n == 0 || n > MAX_KEYS_PER_BUY) revert InvalidKeyCount(n);
        Round storage r = _rounds[_round];
        uint256 start = (r.end == 0 || block.timestamp >= r.end) ? BASE_PRICE : r.nextPrice;
        (cost,) = _cost(start, n);
    }

    /// @notice Keys held by `account` in round `id`.
    function keysOf(uint256 id, address account) external view returns (uint256) {
        return _keys[id][account];
    }

    /// @notice Total keys sold in round `id`.
    function totalKeys(uint256 id) external view returns (uint256) {
        return _rounds[id].totalKeys;
    }

    /// @notice Whether `account` has already claimed its share of round `id`.
    function claimed(uint256 id, address account) external view returns (bool) {
        return _claimed[id][account];
    }

    /// @notice Share `account` could still claim from round `id` (0 if unsettled or claimed).
    function claimable(uint256 id, address account) external view returns (uint256) {
        Round storage r = _rounds[id];
        if (!r.settled || _claimed[id][account]) return 0;
        return _keys[id][account] * r.perKey;
    }

    /// @notice DOOM credited to `account` and payable by `withdraw()`.
    function withdrawable(address account) external view returns (uint256) {
        return _withdrawable[account];
    }

    /// @notice Full state of round `id`.
    function roundInfo(uint256 id) external view returns (Round memory) {
        return _rounds[id];
    }

    /// @notice True when the current round is open and its timer has expired.
    function hasEnded() external view returns (bool) {
        uint256 e = _rounds[_round].end;
        return e != 0 && block.timestamp >= e;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Settles round `id`. Requires `r.end != 0`, which implies `r.totalKeys > 0`.
    function _settle(uint256 id, Round storage r) private {
        uint256 total = r.pot;
        uint256 keys = r.totalKeys;
        address winner = r.lastBuyer;

        uint256 prize = (total * WINNER_BPS) / BPS;
        uint256 perKey = (total * SHARE_BPS) / BPS / keys;
        uint256 shares = perKey * keys;
        uint256 newCarry = total - prize - shares;

        r.settled = true;
        r.perKey = perKey;
        _withdrawable[winner] += prize;
        _carry = newCarry;
        _round = id + 1;

        emit Settled(id, winner, prize, perKey, newCarry);
    }

    /// @dev Total cost of `n` keys starting at `price`, and the price of the key after them.
    function _cost(uint256 price, uint256 n) private pure returns (uint256 cost, uint256 next) {
        next = price;
        for (uint256 i; i < n; ++i) {
            cost += next;
            next = (next * PRICE_NUM + PRICE_DEN - 1) / PRICE_DEN;
        }
    }
}
