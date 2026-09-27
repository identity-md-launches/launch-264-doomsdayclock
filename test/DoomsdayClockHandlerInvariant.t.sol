// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

/// @title Adversarial handler for DoomsdayClock
/// @dev Drives buy / settle / claimShare / withdraw under warped time and keeps ghost accounting
/// so the invariants can be checked against an independent record. Every action is guarded so
/// the handler itself never reverts (fail_on_revert = true): expected failures are caught with
/// try/catch and their selector is asserted, so the failure paths are exercised on every run
/// rather than skipped.
///
/// Actors:
/// - actors[0..NUM_FUNDED-1]: funded and approved players.
/// - poor: approved but holds only a few DOOM, so most purchases fail on balance.
/// - stranger: funded but never approved the clock, so every purchase fails on allowance.
contract AdversarialClockHandler is Test {
    LaunchToken public token;
    DoomsdayClock public clock;

    address[] public actors;
    address public poor;
    address public stranger;

    // ------------------------------------------------------------------
    // Ghost accounting
    // ------------------------------------------------------------------

    /// @dev DOOM each actor has paid into the clock.
    mapping(address => uint256) public paidIn;
    /// @dev DOOM each actor has received from withdraw().
    mapping(address => uint256) public paidOut;
    /// @dev Token balance of each actor at construction.
    mapping(address => uint256) public initialBalance;

    /// @dev Sum of claimShare() amounts credited per round.
    mapping(uint256 => uint256) public sharesPaid;
    /// @dev Prize credited to the last buyer per round (recorded from the Settled state).
    mapping(uint256 => uint256) public prizePaid;
    /// @dev DOOM paid for keys per round.
    mapping(uint256 => uint256) public keyCost;
    /// @dev Carry folded into the round's pot when it opened.
    mapping(uint256 => uint256) public carryIn;
    /// @dev Keys bought per round, by the handler's own count.
    mapping(uint256 => uint256) public ghostKeys;
    /// @dev Keys bought per round per actor, by the handler's own count.
    mapping(uint256 => mapping(address => uint256)) public ghostKeysOf;
    /// @dev Independently computed price of the next key of the round.
    mapping(uint256 => uint256) public ghostNextPrice;
    /// @dev Highest round the handler has seen open.
    uint256 public highestOpened;

    uint256 public totalPaidIn;
    uint256 public totalPaidOut;

    // Activity counters (for afterInvariant logging and sanity).
    uint256 public buys;
    uint256 public buysThatSettled;
    uint256 public buysAtExactEnd;
    uint256 public settlements;
    uint256 public claims;
    uint256 public withdrawals;
    uint256 public expectedFailures;

    uint256 internal constant NUM_FUNDED = 5;
    uint256 internal constant ONE = 1e18;

    constructor(LaunchToken token_, DoomsdayClock clock_, address[] memory actors_, address poor_, address stranger_) {
        token = token_;
        clock = clock_;
        actors = actors_;
        poor = poor_;
        stranger = stranger_;
        for (uint256 i; i < actors_.length; ++i) {
            initialBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Any actor, including the poor and the stranger.
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Only funded, approved players.
    function _player(uint256 seed) internal view returns (address) {
        return actors[seed % NUM_FUNDED];
    }

    function _ceil1001(uint256 p) internal pure returns (uint256) {
        return (p * 1001 + 999) / 1000;
    }

    function _selector(bytes memory err) internal pure returns (bytes4) {
        return bytes4(err);
    }

    /// @dev Moves time in one of four ways: a small step, to one second before the end, to the
    /// exact end, or well past the end (up to several days). Ended rounds stay ended, so long
    /// jumps also exercise "nobody plays for a while".
    function _warp(uint8 mode, uint256 delta) internal {
        uint256 e = clock.end();
        mode = uint8(bound(mode, 0, 3));
        if (mode == 0) {
            vm.warp(block.timestamp + bound(delta, 0, 30 minutes));
        } else if (mode == 1) {
            if (e > block.timestamp + 1) vm.warp(e - 1);
        } else if (mode == 2) {
            if (e > block.timestamp) vm.warp(e);
        } else {
            uint256 base = e > block.timestamp ? e : block.timestamp;
            vm.warp(base + bound(delta, 0, 3 days));
        }
    }

    /// @dev Records what the settlement of the current (ended) round must produce, then returns
    /// the carry the next round has to open with.
    function _expectSettlement(uint256 id) internal view returns (uint256 prize, uint256 perKey, uint256 newCarry) {
        DoomsdayClock.Round memory r = clock.roundInfo(id);
        assertFalse(r.settled, "current round must not be settled yet");
        assertGt(r.totalKeys, 0, "ended round has keys");
        prize = r.pot * 5000 / 10_000;
        perKey = (r.pot * 3000 / 10_000) / r.totalKeys;
        newCarry = r.pot - prize - perKey * r.totalKeys;
    }

    function _afterSettlement(uint256 id, address winner, uint256 prize, uint256 perKey, uint256 newCarry) internal {
        DoomsdayClock.Round memory r = clock.roundInfo(id);
        assertTrue(r.settled, "round settled");
        assertEq(r.perKey, perKey, "perKey");
        assertEq(r.lastBuyer, winner, "winner recorded");
        assertEq(clock.round(), id + 1, "round advanced");
        prizePaid[id] = prize;
        // The winner's credit grew by exactly the prize; nothing else moves withdrawable here.
        settlements++;
        newCarry; // consumed by callers that check carry() or the new pot
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    function warp(uint8 mode, uint256 delta) external {
        _warp(mode, delta);
    }

    // ------------------------------------------------------------------
    // buyKeys
    // ------------------------------------------------------------------

    /// @notice A funded player buys keys after moving time. If the round has ended the purchase
    /// settles it first and the handler checks that settlement against its own arithmetic.
    function buy(uint256 actorSeed, uint256 n, uint8 mode, uint256 delta) external {
        n = bound(n, 1, 100);
        _warp(mode, delta);
        _buyAs(_player(actorSeed), n);
    }

    /// @notice Buy in the same second as `end`: the round must settle, not extend.
    function buyAtExactEnd(uint256 actorSeed, uint256 n) external {
        n = bound(n, 1, 100);
        uint256 e = clock.end();
        if (e == 0) return;
        if (e > block.timestamp) vm.warp(e);
        uint256 idBefore = clock.round();
        _buyAs(_player(actorSeed), n);
        assertEq(clock.round(), idBefore + 1, "buy at exact end opens the next round");
        assertTrue(clock.roundInfo(idBefore).settled, "buy at exact end settles");
        buysAtExactEnd++;
    }

    /// @dev Snapshot taken before a purchase so the outcome can be checked afterwards.
    struct BuySnap {
        uint256 id;
        bool ended;
        address winner;
        uint256 winnerCreditBefore;
        uint256 prize;
        uint256 perKey;
        uint256 newCarry;
        uint256 carryBefore;
        uint256 potBefore;
        uint256 endBefore;
        uint256 clockBalBefore;
        uint256 quote;
    }

    function _snapshot(uint256 n) internal view returns (BuySnap memory s) {
        s.quote = clock.priceOfNext(n);
        s.id = clock.round();
        s.ended = clock.hasEnded();
        if (s.ended) {
            s.winner = clock.lastBuyer();
            s.winnerCreditBefore = clock.withdrawable(s.winner);
            (s.prize, s.perKey, s.newCarry) = _expectSettlement(s.id);
        }
        s.carryBefore = clock.carry();
        s.potBefore = clock.pot();
        s.endBefore = clock.end();
        s.clockBalBefore = token.balanceOf(address(clock));
    }

    function _buyAs(address who, uint256 n) internal {
        BuySnap memory s = _snapshot(n);
        if (token.balanceOf(who) < s.quote) return;

        vm.prank(who);
        uint256 paid = clock.buyKeys(n, s.quote);
        assertEq(paid, s.quote, "quote must equal payment");

        if (s.ended) {
            _afterSettlement(s.id, s.winner, s.prize, s.perKey, s.newCarry);
            assertEq(clock.withdrawable(s.winner), s.winnerCreditBefore + s.prize, "prize credited on settle-by-buy");
            buysThatSettled++;
            s.id = s.id + 1;
            s.carryBefore = s.newCarry;
            s.potBefore = 0;
            s.endBefore = 0;
        }

        _checkAfterBuy(s, who, n, paid);
        _walkPrice(s.id, n, paid);

        keyCost[s.id] += paid;
        ghostKeys[s.id] += n;
        ghostKeysOf[s.id][who] += n;
        paidIn[who] += paid;
        totalPaidIn += paid;
        buys++;
    }

    function _checkAfterBuy(BuySnap memory s, address who, uint256 n, uint256 paid) internal {
        // Round opening: pot starts from the carry, timer from now + 1h, price from base.
        if (s.endBefore == 0) {
            assertEq(s.potBefore, 0, "unopened round has no pot");
            carryIn[s.id] = s.carryBefore;
            ghostNextPrice[s.id] = ONE;
            highestOpened = s.id;
            assertEq(clock.carry(), 0, "carry folded in at opening");
            assertEq(clock.end(), block.timestamp + 1 hours + 30 * n, "opening timer");
            assertEq(clock.pot(), s.carryBefore + paid, "opening pot");
        } else {
            assertEq(clock.carry(), s.carryBefore, "carry untouched mid-round");
            assertEq(clock.pot(), s.potBefore + paid, "pot grows by cost");
            uint256 want = s.endBefore + 30 * n;
            uint256 cap = block.timestamp + 24 hours;
            assertEq(clock.end(), want > cap ? cap : want, "end extension");
            assertGe(clock.end(), s.endBefore, "end never decreases");
        }
        assertLe(clock.end(), block.timestamp + 24 hours, "24h cap");
        assertEq(clock.lastBuyer(), who, "buyer becomes last buyer");
        assertEq(token.balanceOf(address(clock)), s.clockBalBefore + paid, "DOOM received");
    }

    /// @dev Independent price walk: the batch must cost exactly the ceil sequence.
    function _walkPrice(uint256 id, uint256 n, uint256 paid) internal {
        uint256 p = ghostNextPrice[id];
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += p;
            p = _ceil1001(p);
        }
        assertEq(sum, paid, "price sequence");
        ghostNextPrice[id] = p;
    }

    /// @notice maxCost one below the quote must revert with CostExceedsMax and change nothing.
    function buyOverMax(uint256 actorSeed, uint256 n) external {
        n = bound(n, 1, 100);
        address who = _player(actorSeed);
        uint256 quote = clock.priceOfNext(n);
        uint256 bal = token.balanceOf(address(clock));
        uint256 idBefore = clock.round();
        uint256 endBefore = clock.end();
        vm.prank(who);
        try clock.buyKeys(n, quote - 1) returns (uint256) {
            assertTrue(false, "buyKeys above maxCost must revert");
        } catch (bytes memory err) {
            assertEq(_selector(err), DoomsdayClock.CostExceedsMax.selector, "CostExceedsMax");
            assertEq(err, abi.encodeWithSelector(DoomsdayClock.CostExceedsMax.selector, quote, quote - 1));
        }
        assertEq(token.balanceOf(address(clock)), bal, "no DOOM moved");
        assertEq(clock.round(), idBefore, "revert must not settle");
        assertEq(clock.end(), endBefore, "revert must not extend");
        expectedFailures++;
    }

    /// @notice n == 0 and n == 101 must revert with InvalidKeyCount.
    function buyBadCount(uint256 actorSeed, bool over) external {
        uint256 n = over ? 101 : 0;
        address who = _player(actorSeed);
        uint256 bal = token.balanceOf(address(clock));
        vm.prank(who);
        try clock.buyKeys(n, type(uint256).max) returns (uint256) {
            assertTrue(false, "invalid key count must revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(DoomsdayClock.InvalidKeyCount.selector, n));
        }
        assertEq(token.balanceOf(address(clock)), bal, "no DOOM moved");
        expectedFailures++;
    }

    /// @notice The stranger never approved: the purchase must fail on allowance, not partially
    /// apply state (the token pull is the last step, so a revert there must roll back the round).
    function buyWithoutAllowance(uint256 n) external {
        n = bound(n, 1, 100);
        uint256 quote = clock.priceOfNext(n);
        uint256 idBefore = clock.round();
        uint256 endBefore = clock.end();
        uint256 potBefore = clock.pot();
        address lastBefore = clock.lastBuyer();
        vm.prank(stranger);
        try clock.buyKeys(n, quote) returns (uint256) {
            assertTrue(false, "unapproved buy must revert");
        } catch (bytes memory err) {
            assertEq(_selector(err), IERC20Errors.ERC20InsufficientAllowance.selector, "allowance error");
        }
        assertEq(clock.round(), idBefore, "round unchanged");
        assertEq(clock.end(), endBefore, "end unchanged");
        assertEq(clock.pot(), potBefore, "pot unchanged");
        assertEq(clock.lastBuyer(), lastBefore, "lastBuyer unchanged");
        assertEq(clock.keysOf(idBefore, stranger), 0, "no keys for the stranger");
        expectedFailures++;
    }

    /// @notice The poor actor has a few DOOM: small buys may succeed, big ones must fail on
    /// balance without touching state.
    function buyAsPoor(uint256 n) external {
        n = bound(n, 1, 100);
        uint256 quote = clock.priceOfNext(n);
        if (token.balanceOf(poor) >= quote) {
            _buyAs(poor, n);
            return;
        }
        uint256 idBefore = clock.round();
        uint256 endBefore = clock.end();
        uint256 potBefore = clock.pot();
        vm.prank(poor);
        try clock.buyKeys(n, quote) returns (uint256) {
            assertTrue(false, "underfunded buy must revert");
        } catch (bytes memory err) {
            assertEq(_selector(err), IERC20Errors.ERC20InsufficientBalance.selector, "balance error");
        }
        assertEq(clock.round(), idBefore, "round unchanged");
        assertEq(clock.end(), endBefore, "end unchanged");
        assertEq(clock.pot(), potBefore, "pot unchanged");
        expectedFailures++;
    }

    // ------------------------------------------------------------------
    // settle
    // ------------------------------------------------------------------

    function settle(uint8 mode, uint256 delta) external {
        _warp(mode, delta);
        if (!clock.hasEnded()) {
            // Not ended (or never opened): settle must revert.
            try clock.settle() {
                assertTrue(false, "settle before end must revert");
            } catch (bytes memory err) {
                assertEq(_selector(err), DoomsdayClock.RoundNotEnded.selector, "RoundNotEnded");
            }
            expectedFailures++;
            return;
        }
        uint256 id = clock.round();
        address winner = clock.lastBuyer();
        uint256 winnerCreditBefore = clock.withdrawable(winner);
        (uint256 prize, uint256 perKey, uint256 newCarry) = _expectSettlement(id);
        uint256 bal = token.balanceOf(address(clock));

        vm.prank(_actor(delta)); // anyone may settle
        clock.settle();

        _afterSettlement(id, winner, prize, perKey, newCarry);
        assertEq(clock.withdrawable(winner), winnerCreditBefore + prize, "prize credited");
        assertEq(clock.carry(), newCarry, "carry after settle");
        assertEq(clock.pot(), 0, "new round has no pot");
        assertEq(clock.end(), 0, "new round not open");
        assertEq(clock.lastBuyer(), address(0), "new round has no buyer");
        assertEq(token.balanceOf(address(clock)), bal, "settle moves no DOOM");

        // Settling twice must revert.
        try clock.settle() {
            assertTrue(false, "second settle must revert");
        } catch (bytes memory err) {
            assertEq(_selector(err), DoomsdayClock.RoundNotEnded.selector, "settle twice");
        }
        expectedFailures++;
    }

    // ------------------------------------------------------------------
    // claimShare
    // ------------------------------------------------------------------

    /// @notice Claim from a settled round, then prove a second claim reverts.
    function claim(uint256 actorSeed, uint256 roundSeed) external {
        uint256 current = clock.round();
        if (current < 2) return;
        uint256 id = 1 + (roundSeed % (current - 1));
        address who = _actor(actorSeed);
        uint256 keys = clock.keysOf(id, who);
        DoomsdayClock.Round memory r = clock.roundInfo(id);
        assertTrue(r.settled, "past rounds are settled");

        if (keys == 0) {
            vm.prank(who);
            try clock.claimShare(id) returns (uint256) {
                assertTrue(false, "claim without keys must revert");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(DoomsdayClock.NoKeys.selector, id, who));
            }
            assertEq(clock.claimable(id, who), 0);
            expectedFailures++;
            // Then find someone who does hold keys in that round so real claims stay frequent.
            who = address(0);
            uint256 start = actorSeed % actors.length;
            for (uint256 i; i < actors.length; ++i) {
                address cand = actors[(start + i) % actors.length];
                if (clock.keysOf(id, cand) != 0) {
                    who = cand;
                    break;
                }
            }
            if (who == address(0)) return;
            keys = clock.keysOf(id, who);
        }

        if (clock.claimed(id, who)) {
            vm.prank(who);
            try clock.claimShare(id) returns (uint256) {
                assertTrue(false, "double claim must revert");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(DoomsdayClock.AlreadyClaimed.selector, id, who));
            }
            assertEq(clock.claimable(id, who), 0);
            expectedFailures++;
            return;
        }

        uint256 expected = keys * r.perKey;
        assertEq(clock.claimable(id, who), expected, "claimable quote");
        uint256 creditBefore = clock.withdrawable(who);
        uint256 bal = token.balanceOf(address(clock));

        vm.prank(who);
        uint256 amount = clock.claimShare(id);

        assertEq(amount, expected, "claim amount");
        assertEq(clock.withdrawable(who), creditBefore + amount, "claim credits withdrawable");
        assertTrue(clock.claimed(id, who), "marked claimed");
        assertEq(clock.claimable(id, who), 0, "nothing left to claim");
        assertEq(token.balanceOf(address(clock)), bal, "claim moves no DOOM");
        sharesPaid[id] += amount;
        claims++;

        // Same call twice: must revert and credit nothing more.
        vm.prank(who);
        try clock.claimShare(id) returns (uint256) {
            assertTrue(false, "claimShare twice must revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(DoomsdayClock.AlreadyClaimed.selector, id, who));
        }
        assertEq(clock.withdrawable(who), creditBefore + amount, "double claim credited nothing");
        expectedFailures++;
    }

    /// @notice Claims on the current (unsettled) round and on future ids must revert.
    function claimUnsettled(uint256 actorSeed, uint256 ahead) external {
        uint256 id = clock.round() + bound(ahead, 0, 5);
        address who = _actor(actorSeed);
        vm.prank(who);
        try clock.claimShare(id) returns (uint256) {
            assertTrue(false, "claim on unsettled round must revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(DoomsdayClock.RoundNotSettled.selector, id));
        }
        assertEq(clock.claimable(id, who), 0);
        expectedFailures++;
    }

    // ------------------------------------------------------------------
    // withdraw
    // ------------------------------------------------------------------

    function withdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 owed = clock.withdrawable(who);
        if (owed == 0) {
            vm.prank(who);
            try clock.withdraw() returns (uint256) {
                assertTrue(false, "withdraw with nothing owed must revert");
            } catch (bytes memory err) {
                assertEq(_selector(err), DoomsdayClock.NothingToWithdraw.selector, "NothingToWithdraw");
            }
            expectedFailures++;
            return;
        }
        uint256 before = token.balanceOf(who);
        uint256 clockBefore = token.balanceOf(address(clock));
        vm.prank(who);
        uint256 paid = clock.withdraw();
        assertEq(paid, owed, "withdraw pays what was credited");
        assertEq(token.balanceOf(who), before + owed, "actor received");
        assertEq(token.balanceOf(address(clock)), clockBefore - owed, "clock paid");
        assertEq(clock.withdrawable(who), 0, "credit cleared");
        paidOut[who] += paid;
        totalPaidOut += paid;
        withdrawals++;

        // Immediately again: nothing left.
        vm.prank(who);
        try clock.withdraw() returns (uint256) {
            assertTrue(false, "second withdraw must revert");
        } catch (bytes memory err) {
            assertEq(_selector(err), DoomsdayClock.NothingToWithdraw.selector, "withdraw twice");
        }
        assertEq(token.balanceOf(who), before + owed, "second withdraw paid nothing");
        expectedFailures++;
    }
}

contract DoomsdayClockHandlerInvariantTest is Test {
    LaunchToken internal token;
    DoomsdayClock internal clock;
    AdversarialClockHandler internal handler;
    address[] internal actors;
    address internal poor;
    address internal stranger;

    uint256 internal constant START = 1_800_000_000;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        clock = new DoomsdayClock(address(token));

        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string.concat("adv-player", vm.toString(i)));
            actors.push(a);
            token.transfer(a, 100_000_000 * 1e18);
            vm.prank(a);
            token.approve(address(clock), type(uint256).max);
        }
        poor = makeAddr("adv-poor");
        token.transfer(poor, 5 * 1e18);
        vm.prank(poor);
        token.approve(address(clock), type(uint256).max);
        actors.push(poor);

        stranger = makeAddr("adv-stranger");
        token.transfer(stranger, 1_000_000 * 1e18);
        actors.push(stranger);

        handler = new AdversarialClockHandler(token, clock, actors, poor, stranger);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _unclaimedShares() internal view returns (uint256 unclaimed) {
        uint256 current = clock.round();
        for (uint256 id = 1; id < current; ++id) {
            for (uint256 i; i < actors.length; ++i) {
                unclaimed += clock.claimable(id, actors[i]);
            }
        }
    }

    function _sumWithdrawable() internal view returns (uint256 credited) {
        for (uint256 i; i < actors.length; ++i) {
            credited += clock.withdrawable(actors[i]);
        }
    }

    // ------------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------------

    /// @dev DOOM held == current pot + carry + unclaimed shares + sum(withdrawable).
    /// Unclaimed shares are summed from `claimable` per actor, so a share the contract would
    /// pay but the ghost did not expect (or vice versa) breaks the equation.
    function invariant_conservation() public view {
        uint256 held = token.balanceOf(address(clock));
        assertEq(held, clock.pot() + clock.carry() + _unclaimedShares() + _sumWithdrawable(), "conservation");
        assertEq(held, handler.totalPaidIn() - handler.totalPaidOut(), "ghost flow");
        assertEq(address(clock).balance, 0, "never holds ETH");
    }

    /// @dev Sum of shares actually paid per round <= 30% of that round's pot, and prize plus the
    /// full share allotment plus carry reconstructs the pot exactly.
    function invariant_sharesPerRoundWithin30Percent() public view {
        uint256 current = clock.round();
        for (uint256 id = 1; id < current; ++id) {
            DoomsdayClock.Round memory r = clock.roundInfo(id);
            assertTrue(r.settled, "past round settled");
            uint256 cap = r.pot * 3000 / 10_000;
            uint256 allotment = r.perKey * r.totalKeys;
            uint256 paid = handler.sharesPaid(id);
            assertLe(paid, allotment, "paid shares within allotment");
            assertLe(allotment, cap, "allotment within 30%");
            assertLt(cap - allotment, r.totalKeys, "allotment is the floor: dust below one per-key unit");
            // Paid so far plus what is still claimable equals the allotment.
            uint256 stillClaimable;
            for (uint256 i; i < actors.length; ++i) {
                stillClaimable += clock.claimable(id, actors[i]);
            }
            assertEq(paid + stillClaimable, allotment, "shares are conserved");
            // Prize + allotment + carry-out == pot.
            uint256 prize = r.pot * 5000 / 10_000;
            assertEq(handler.prizePaid(id), prize, "prize recorded");
            uint256 carryOut = r.pot - prize - allotment;
            assertGe(carryOut, r.pot * 2000 / 10_000, "carry at least 20%");
            if (id + 1 < current || clock.end() != 0) {
                // Round id+1 has opened: its carry-in must equal this round's carry-out.
                assertEq(handler.carryIn(id + 1), carryOut, "carry flows to next round");
            } else {
                // Round id+1 is the current, unopened round: the carry is still pending.
                assertEq(clock.carry(), carryOut, "pending carry");
            }
        }
    }

    /// @dev Round bookkeeping matches the handler's own count.
    function invariant_roundBookkeeping() public view {
        uint256 current = clock.round();
        DoomsdayClock.Round memory cur = clock.roundInfo(current);
        assertFalse(cur.settled, "current round not settled");
        if (cur.end == 0) {
            assertEq(cur.pot, 0, "unopened round has no pot");
            assertEq(cur.totalKeys, 0, "unopened round has no keys");
            assertEq(cur.lastBuyer, address(0), "unopened round has no buyer");
            assertFalse(clock.hasEnded());
        } else {
            assertGt(cur.totalKeys, 0, "open round has keys");
            assertTrue(cur.lastBuyer != address(0), "open round has a buyer");
            assertEq(clock.carry(), 0, "carry is folded while a round is open");
            assertLe(cur.end, block.timestamp + 24 hours, "24h cap");
            assertEq(cur.pot, handler.carryIn(current) + handler.keyCost(current), "pot = carry in + keys");
            if (block.timestamp < cur.end) {
                assertEq(clock.priceOfNext(1), handler.ghostNextPrice(current), "next price");
            } else {
                assertEq(clock.priceOfNext(1), 1e18, "quote resets once ended");
            }
        }
        for (uint256 id = 1; id <= current; ++id) {
            DoomsdayClock.Round memory r = clock.roundInfo(id);
            assertEq(r.totalKeys, handler.ghostKeys(id), "total keys");
            uint256 sumKeys;
            for (uint256 i; i < actors.length; ++i) {
                uint256 k = clock.keysOf(id, actors[i]);
                assertEq(k, handler.ghostKeysOf(id, actors[i]), "keys of actor");
                sumKeys += k;
            }
            assertEq(sumKeys, r.totalKeys, "keys sum to total");
            if (id < current) {
                assertEq(r.pot, handler.carryIn(id) + handler.keyCost(id), "settled pot = carry in + keys");
            }
        }
        // Unopened future rounds are empty.
        DoomsdayClock.Round memory next = clock.roundInfo(current + 1);
        assertEq(next.pot + next.totalKeys + next.end + next.perKey, 0, "future round empty");
        assertFalse(next.settled);
    }

    /// @dev Every actor's balance equals what they started with minus paid in plus paid out.
    /// Nobody can gain DOOM except through withdraw(), and the stranger never moves.
    function invariant_actorBalances() public view {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            assertEq(
                token.balanceOf(a), handler.initialBalance(a) + handler.paidOut(a) - handler.paidIn(a), "actor balance"
            );
        }
        assertEq(handler.paidIn(stranger), 0, "stranger never paid");
        assertEq(clock.keysOf(clock.round(), stranger), 0, "stranger never holds keys");
        assertEq(token.balanceOf(stranger), handler.initialBalance(stranger), "stranger untouched");
    }

    /// @dev After a run, drain everything: settle if ended, claim every share, withdraw every
    /// credit. What remains in the clock must be exactly the live pot plus the carry.
    function afterInvariant() public {
        if (clock.hasEnded()) clock.settle();
        uint256 current = clock.round();
        for (uint256 id = 1; id < current; ++id) {
            for (uint256 i; i < actors.length; ++i) {
                if (clock.claimable(id, actors[i]) == 0) continue;
                vm.prank(actors[i]);
                clock.claimShare(id);
            }
        }
        uint256 expectedOut;
        for (uint256 i; i < actors.length; ++i) {
            uint256 owed = clock.withdrawable(actors[i]);
            if (owed == 0) continue;
            expectedOut += owed;
            vm.prank(actors[i]);
            assertEq(clock.withdraw(), owed);
        }
        assertEq(_unclaimedShares(), 0, "drained shares");
        assertEq(_sumWithdrawable(), 0, "drained credits");
        assertEq(token.balanceOf(address(clock)), clock.pot() + clock.carry(), "only pot and carry remain");
        assertEq(
            token.balanceOf(address(clock)),
            handler.totalPaidIn() - handler.totalPaidOut() - expectedOut,
            "drain matches ghost"
        );
        // Total DOOM is conserved across the clock and every actor.
        uint256 total = token.balanceOf(address(clock));
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
        total += token.balanceOf(address(this));
        assertEq(total, token.totalSupply(), "DOOM supply conserved");

        console2.log("buys", handler.buys());
        console2.log("buys that settled", handler.buysThatSettled());
        console2.log("buys at exact end", handler.buysAtExactEnd());
        console2.log("settlements", handler.settlements());
        console2.log("claims", handler.claims());
        console2.log("withdrawals", handler.withdrawals());
        console2.log("expected failures", handler.expectedFailures());
        console2.log("rounds opened", handler.highestOpened());
    }

    // ------------------------------------------------------------------
    // Scripted walk: every handler path fires at least once, deterministically, and the
    // invariants hold at each step. This guards against a fuzz run that happens to skip a path.
    // ------------------------------------------------------------------

    function _checkAll() internal view {
        invariant_conservation();
        invariant_sharesPerRoundWithin30Percent();
        invariant_roundBookkeeping();
        invariant_actorBalances();
    }

    function test_scriptedWalkCoversEveryHandlerPath() public {
        // Nothing open: settle, claim, withdraw all fail.
        handler.settle(0, 0);
        handler.claimUnsettled(0, 0);
        handler.withdraw(0);
        handler.buyBadCount(0, false);
        handler.buyBadCount(0, true);
        handler.buyWithoutAllowance(3);
        handler.buyAsPoor(100); // 100 keys cost > 5 DOOM: balance failure
        _checkAll();
        assertEq(handler.buys(), 0);

        // Round 1 opens and grows.
        handler.buy(0, 10, 0, 0);
        handler.buyOverMax(1, 4);
        handler.buy(1, 25, 0, 5 minutes);
        handler.buyAsPoor(1); // 1 key at the current price still fits in 5 DOOM
        handler.buyWithoutAllowance(1);
        handler.claimUnsettled(0, 0); // current round not settled
        handler.settle(1, 0); // end - 1: not ended, must fail
        _checkAll();
        assertEq(handler.buys(), 3, "two player buys plus the poor actor's single key");
        assertEq(clock.keysOf(1, poor), 1, "poor actor holds one key");
        assertEq(clock.round(), 1);

        // Buy at exact end: settles round 1 and opens round 2.
        handler.buyAtExactEnd(2, 7);
        _checkAll();
        assertEq(handler.buys(), 4);
        assertEq(clock.round(), 2);
        assertEq(handler.buysThatSettled(), 1);
        assertEq(handler.buysAtExactEnd(), 1);
        assertEq(handler.settlements(), 1);

        // Claims on round 1: holder, non-holder, double.
        handler.claim(0, 0); // actor 0 held keys: claims then double-claim fails
        handler.claim(0, 0); // already claimed: AlreadyClaimed path
        handler.claim(6, 0); // stranger: NoKeys path
        _checkAll();
        assertEq(handler.claims(), 1);

        // Round 1's last buyer was the poor actor (index 5): prize credited, withdraw pays it.
        assertEq(clock.roundInfo(1).lastBuyer, poor, "poor actor was the last buyer of round 1");
        assertEq(clock.withdrawable(poor), clock.roundInfo(1).pot / 2, "prize credited to the poor actor");
        handler.withdraw(5);
        assertEq(handler.withdrawals(), 1);
        assertEq(clock.withdrawable(poor), 0);
        _checkAll();

        // Long jump past round 2's end, settle explicitly, then settle again (fails inside).
        handler.settle(3, 2 days);
        _checkAll();
        assertEq(clock.round(), 3);
        assertEq(clock.end(), 0);
        assertEq(handler.settlements(), 2);

        // Round 3 opens with round 2's carry; then a far jump and a buy that settles it.
        handler.buy(3, 100, 0, 0);
        assertEq(
            handler.carryIn(3),
            clock.roundInfo(2).pot - clock.roundInfo(2).pot / 2 - clock.roundInfo(2).perKey
                * clock.roundInfo(2).totalKeys
        );
        handler.buy(4, 100, 3, 3 days);
        _checkAll();
        assertEq(clock.round(), 4);
        assertEq(handler.buysThatSettled(), 2);

        // Everybody claims and withdraws whatever they can.
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 id = 1; id < clock.round(); ++id) {
                handler.claim(i, id - 1);
            }
            handler.withdraw(i);
        }
        _checkAll();
        assertGt(handler.withdrawals(), 0);
        assertGt(handler.expectedFailures(), 10);

        afterInvariant();
    }
}
