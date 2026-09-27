// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

contract DoomsdayClockTest is Test {
    LaunchToken internal token;
    DoomsdayClock internal clock;

    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant FUND = 10_000_000 * 1e18;

    event KeysBought(uint256 indexed round, address indexed buyer, uint256 n, uint256 cost, uint256 end);
    event Settled(uint256 indexed round, address indexed lastBuyer, uint256 prize, uint256 perKey, uint256 carry);
    event ShareClaimed(uint256 indexed round, address indexed account, uint256 keys, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public {
        vm.warp(START);
        vm.startPrank(factory);
        token = new LaunchToken();
        clock = new DoomsdayClock(address(token));
        token.transfer(alice, FUND);
        token.transfer(bob, FUND);
        token.transfer(carol, FUND);
        vm.stopPrank();

        vm.prank(alice);
        token.approve(address(clock), type(uint256).max);
        vm.prank(bob);
        token.approve(address(clock), type(uint256).max);
        vm.prank(carol);
        token.approve(address(clock), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _ceilMul(uint256 p) internal pure returns (uint256) {
        return (p * 1001 + 999) / 1000;
    }

    /// @dev Independent reference: price of key k and total of keys [from, from+n).
    function _refPrice(uint256 k) internal pure returns (uint256 p) {
        p = ONE;
        for (uint256 i; i < k; ++i) {
            p = _ceilMul(p);
        }
    }

    function _refCost(uint256 from, uint256 n) internal pure returns (uint256 total) {
        uint256 p = _refPrice(from);
        for (uint256 i; i < n; ++i) {
            total += p;
            p = _ceilMul(p);
        }
    }

    function _buy(address who, uint256 n) internal returns (uint256 cost) {
        vm.prank(who);
        cost = clock.buyKeys(n, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    function test_constructorStoresToken() public view {
        assertEq(clock.token(), address(token));
        assertEq(token.balanceOf(address(clock)), 0);
        assertEq(clock.round(), 1);
        assertEq(clock.end(), 0);
        assertEq(clock.pot(), 0);
        assertEq(clock.carry(), 0);
        assertEq(clock.lastBuyer(), address(0));
        assertFalse(clock.hasEnded());
    }

    function test_constructorRejectsZeroAndNonContract() public {
        vm.expectRevert(DoomsdayClock.ZeroToken.selector);
        new DoomsdayClock(address(0));
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.TokenNotContract.selector, alice));
        new DoomsdayClock(alice);
    }

    function test_noPayableEntryPoints() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(clock).call{value: 1}("");
        assertFalse(ok, "plain ETH transfer must fail");
        vm.prank(alice);
        (ok,) = address(clock).call{value: 1}(abi.encodeWithSignature("buyKeys(uint256,uint256)", 1, ONE));
        assertFalse(ok, "value on buyKeys must fail");
        vm.prank(alice);
        (ok,) = address(clock).call{value: 1}(abi.encodeWithSignature("nonexistent()"));
        assertFalse(ok, "no fallback");
        assertEq(address(clock).balance, 0);
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    function test_priceSequenceMatchesCeilReference() public {
        // Buy keys one at a time and compare each quoted price to the reference sequence.
        for (uint256 k; k < 40; ++k) {
            uint256 quoted = clock.priceOfNext(1);
            assertEq(quoted, _refPrice(k), "price_k");
            uint256 paid = _buy(alice, 1);
            assertEq(paid, quoted);
        }
        assertEq(clock.totalKeys(1), 40);
        assertEq(token.balanceOf(address(clock)), _refCost(0, 40));
    }

    function test_priceKnownValuesAndCeilRounding() public {
        // 1.001^k * 1e18 is an integer for k <= 6, then ceil kicks in at k = 7.
        assertEq(_refPrice(0), 1_000_000_000_000_000_000);
        assertEq(_refPrice(1), 1_001_000_000_000_000_000);
        assertEq(_refPrice(2), 1_002_001_000_000_000_000);
        assertEq(_refPrice(6), 1_006_015_020_015_006_001);
        // exact value would be 1007021035035021007.001 -> ceil
        assertEq(_refPrice(7), 1_007_021_035_035_021_008);

        _buy(alice, 7);
        assertEq(clock.priceOfNext(1), 1_007_021_035_035_021_008);
        assertEq(clock.pot(), _refCost(0, 7));
    }

    function test_priceOfNextBatchEqualsSumOfSingles() public {
        _buy(alice, 13);
        uint256 batch = clock.priceOfNext(25);
        assertEq(batch, _refCost(13, 25));
        uint256 paid = _buy(bob, 25);
        assertEq(paid, batch);
        assertEq(clock.priceOfNext(1), _refPrice(38));
    }

    function test_priceOfNextRejectsInvalidCounts() public {
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.InvalidKeyCount.selector, 0));
        clock.priceOfNext(0);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.InvalidKeyCount.selector, 101));
        clock.priceOfNext(101);
    }

    function test_priceOfNextResetsAfterRoundEnds() public {
        _buy(alice, 50);
        assertEq(clock.priceOfNext(1), _refPrice(50));
        vm.warp(clock.end());
        // Round has ended: the next purchase opens a new round at the base price.
        assertEq(clock.priceOfNext(1), ONE);
        assertEq(clock.priceOfNext(3), _refCost(0, 3));
        uint256 paid = _buy(bob, 3);
        assertEq(paid, _refCost(0, 3));
        assertEq(clock.round(), 2);
    }

    function testFuzz_priceIsMonotoneAndCeiled(uint8 n) public {
        n = uint8(bound(n, 1, 100));
        _buy(alice, n);
        uint256 prev = _refPrice(n - 1);
        uint256 next = clock.priceOfNext(1);
        assertGe(next * 1000, prev * 1001, "ceil must not round down");
        assertLt(next * 1000, prev * 1001 + 1000, "ceil must be tight");
    }

    // ------------------------------------------------------------------
    // buyKeys
    // ------------------------------------------------------------------

    function test_firstBuyOpensRoundAndEmits() public {
        uint256 expectedEnd = START + 1 hours + 30 seconds * 3;
        vm.expectEmit(true, true, true, true, address(clock));
        emit KeysBought(1, alice, 3, _refCost(0, 3), expectedEnd);
        uint256 cost = _buy(alice, 3);

        assertEq(cost, _refCost(0, 3));
        assertEq(clock.end(), expectedEnd);
        assertEq(clock.pot(), cost);
        assertEq(clock.lastBuyer(), alice);
        assertEq(clock.keysOf(1, alice), 3);
        assertEq(clock.totalKeys(1), 3);
        assertEq(token.balanceOf(address(clock)), cost);
        assertEq(token.balanceOf(alice), FUND - cost);
    }

    function test_buyRejectsZeroAndOver100Keys() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.InvalidKeyCount.selector, 0));
        clock.buyKeys(0, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.InvalidKeyCount.selector, 101));
        clock.buyKeys(101, type(uint256).max);

        // 100 is allowed.
        uint256 cost = _buy(alice, 100);
        assertEq(cost, _refCost(0, 100));
        assertEq(clock.keysOf(1, alice), 100);
    }

    function test_maxCostGuardReverts() public {
        uint256 quote = clock.priceOfNext(5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.CostExceedsMax.selector, quote, quote - 1));
        clock.buyKeys(5, quote - 1);

        // Exactly the quote succeeds.
        vm.prank(alice);
        assertEq(clock.buyKeys(5, quote), quote);
    }

    function test_maxCostProtectsAgainstFrontRun() public {
        uint256 quote = clock.priceOfNext(10);
        // Bob buys first, raising the price.
        _buy(bob, 10);
        uint256 newQuote = clock.priceOfNext(10);
        assertGt(newQuote, quote);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.CostExceedsMax.selector, newQuote, quote));
        clock.buyKeys(10, quote);
    }

    function test_buyRevertsWithoutAllowanceOrBalance() public {
        address dave = makeAddr("dave");
        vm.prank(factory);
        token.transfer(dave, 10 * ONE);

        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(clock), 0, ONE)
        );
        clock.buyKeys(1, ONE);

        vm.prank(dave);
        token.approve(address(clock), type(uint256).max);
        uint256 cost = clock.priceOfNext(11);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, dave, 10 * ONE, cost));
        clock.buyKeys(11, type(uint256).max);
    }

    function test_eachKeyAdds30SecondsAndLastBuyerUpdates() public {
        _buy(alice, 1);
        uint256 e = clock.end();
        assertEq(e, START + 1 hours + 30);

        vm.warp(START + 10 minutes);
        _buy(bob, 4);
        assertEq(clock.end(), e + 120);
        assertEq(clock.lastBuyer(), bob);

        _buy(alice, 2);
        assertEq(clock.end(), e + 180);
        assertEq(clock.lastBuyer(), alice);
        assertEq(clock.keysOf(1, alice), 3);
        assertEq(clock.keysOf(1, bob), 4);
        assertEq(clock.totalKeys(1), 7);
    }

    function test_24HourCap() public {
        _buy(alice, 1);
        // Buy until the cap binds: 100 keys add 50 minutes each call.
        for (uint256 i; i < 30; ++i) {
            _buy(bob, 100);
        }
        assertEq(clock.end(), START + 24 hours, "cap binds");

        // Further keys cannot push past now + 24h.
        _buy(alice, 100);
        assertEq(clock.end(), START + 24 hours);

        // Moving forward in time moves the cap forward by the same amount. The first buy after
        // the warp adds its 50 minutes uncapped because the cap moved 2 hours ahead...
        vm.warp(START + 2 hours);
        _buy(carol, 100);
        assertEq(clock.end(), START + 24 hours + 50 minutes);
        // ...and three more 100-key buys (150 minutes) would overshoot, so the cap binds again.
        _buy(carol, 100);
        _buy(carol, 100);
        _buy(carol, 100);
        assertEq(clock.end(), START + 2 hours + 24 hours);

        // A small buy that does not reach the cap adds exactly 30s per key from the old end.
        vm.warp(START + 3 hours);
        uint256 before = clock.end();
        _buy(alice, 2);
        assertEq(clock.end(), before + 60);
        assertLe(clock.end(), block.timestamp + 24 hours);
    }

    function testFuzz_endNeverExceeds24Hours(uint8 n, uint32 delay) public {
        n = uint8(bound(n, 1, 100));
        delay = uint32(bound(delay, 0, 3 hours));
        _buy(alice, 100);
        for (uint256 i; i < 28; ++i) {
            _buy(bob, 100);
        }
        vm.warp(block.timestamp + delay);
        if (clock.hasEnded()) return;
        uint256 before = clock.end();
        _buy(carol, n);
        assertLe(clock.end(), block.timestamp + 24 hours);
        assertGe(clock.end(), before);
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    function test_settleRevertsBeforeEndAndWithoutRound() public {
        vm.expectRevert(DoomsdayClock.RoundNotEnded.selector);
        clock.settle();

        _buy(alice, 1);
        vm.warp(clock.end() - 1);
        vm.expectRevert(DoomsdayClock.RoundNotEnded.selector);
        clock.settle();
    }

    function test_settleAtExactEndSplitsPot() public {
        uint256 aCost = _buy(alice, 10);
        uint256 bCost = _buy(bob, 5);
        uint256 total = aCost + bCost;
        uint256 prize = total / 2;
        uint256 perKey = (total * 3 / 10) / 15;
        uint256 carry = total - prize - perKey * 15;

        vm.warp(clock.end());
        assertTrue(clock.hasEnded());

        vm.expectEmit(true, true, true, true, address(clock));
        emit Settled(1, bob, prize, perKey, carry);
        vm.prank(carol); // anyone
        clock.settle();

        assertEq(clock.round(), 2);
        assertEq(clock.end(), 0);
        assertEq(clock.pot(), 0);
        assertEq(clock.carry(), carry);
        assertEq(clock.lastBuyer(), address(0));
        assertEq(clock.withdrawable(bob), prize);
        assertEq(clock.withdrawable(alice), 0);
        assertGe(carry, total * 2 / 10, "carry is at least 20%");

        DoomsdayClock.Round memory r = clock.roundInfo(1);
        assertTrue(r.settled);
        assertEq(r.perKey, perKey);
        assertEq(r.pot, total);
        assertEq(r.totalKeys, 15);
        assertEq(r.lastBuyer, bob);
    }

    function test_settleTwiceReverts() public {
        _buy(alice, 1);
        vm.warp(clock.end());
        clock.settle();
        vm.expectRevert(DoomsdayClock.RoundNotEnded.selector);
        clock.settle();
    }

    function test_buyAfterEndSettlesFirstAndOpensNextRound() public {
        uint256 c1 = _buy(alice, 20);
        uint256 endTime = clock.end();
        vm.warp(endTime + 5);

        uint256 prize = c1 / 2;
        uint256 perKey = (c1 * 3 / 10) / 20;
        uint256 carry = c1 - prize - perKey * 20;
        uint256 c2 = _refCost(0, 2);

        vm.expectEmit(true, true, true, true, address(clock));
        emit Settled(1, alice, prize, perKey, carry);
        vm.expectEmit(true, true, true, true, address(clock));
        emit KeysBought(2, bob, 2, c2, endTime + 5 + 1 hours + 60);
        uint256 paid = _buy(bob, 2);

        assertEq(paid, c2, "new round starts at base price");
        assertEq(clock.round(), 2);
        assertEq(clock.carry(), 0, "carry folded into the new pot");
        assertEq(clock.pot(), carry + c2);
        assertEq(clock.lastBuyer(), bob);
        assertEq(clock.keysOf(2, bob), 2);
        assertEq(clock.keysOf(2, alice), 0);
        assertEq(clock.withdrawable(alice), prize);
        assertEq(clock.end(), endTime + 5 + 1 hours + 60);
    }

    function test_buyInSameSecondAsEndSettles() public {
        _buy(alice, 1);
        uint256 endTime = clock.end();

        // One second before the end the round continues.
        vm.warp(endTime - 1);
        _buy(bob, 1);
        assertEq(clock.round(), 1);
        assertEq(clock.end(), endTime + 30);

        // At exactly end the round is over: a buy settles round 1 and opens round 2.
        vm.warp(endTime + 30);
        _buy(carol, 1);
        assertEq(clock.round(), 2);
        assertEq(clock.keysOf(2, carol), 1);
        assertEq(clock.withdrawable(bob), clock.roundInfo(1).pot / 2);
    }

    function test_roundWithNoKeysNeverStarts() public {
        _buy(alice, 1);
        vm.warp(clock.end());
        clock.settle();
        // Round 2 exists as an id but has no timer until a key is bought.
        assertEq(clock.round(), 2);
        assertEq(clock.end(), 0);
        assertFalse(clock.hasEnded());
        vm.warp(block.timestamp + 30 days);
        assertEq(clock.round(), 2);
        assertFalse(clock.hasEnded());
        vm.expectRevert(DoomsdayClock.RoundNotEnded.selector);
        clock.settle();
        _buy(bob, 1);
        assertEq(clock.round(), 2);
        assertEq(clock.end(), block.timestamp + 1 hours + 30);
    }

    // ------------------------------------------------------------------
    // Shares and withdrawals
    // ------------------------------------------------------------------

    function test_claimShareAndWithdraw() public {
        uint256 aCost = _buy(alice, 30);
        uint256 bCost = _buy(bob, 10);
        uint256 total = aCost + bCost;
        uint256 perKey = (total * 3 / 10) / 40;
        vm.warp(clock.end());
        clock.settle();

        assertEq(clock.claimable(1, alice), perKey * 30);
        assertEq(clock.claimable(1, bob), perKey * 10);
        assertEq(clock.claimable(1, carol), 0);

        vm.expectEmit(true, true, true, true, address(clock));
        emit ShareClaimed(1, alice, 30, perKey * 30);
        vm.prank(alice);
        assertEq(clock.claimShare(1), perKey * 30);
        assertEq(clock.withdrawable(alice), perKey * 30);
        assertEq(clock.claimable(1, alice), 0);
        assertTrue(clock.claimed(1, alice));

        // Bob is the last buyer: prize plus his per-key share.
        vm.prank(bob);
        clock.claimShare(1);
        assertEq(clock.withdrawable(bob), total / 2 + perKey * 10);

        uint256 balBefore = token.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(clock));
        emit Withdrawn(bob, total / 2 + perKey * 10);
        vm.prank(bob);
        assertEq(clock.withdraw(), total / 2 + perKey * 10);
        assertEq(token.balanceOf(bob), balBefore + total / 2 + perKey * 10);
        assertEq(clock.withdrawable(bob), 0);

        // Shares paid never exceed 30% of the pot.
        assertLe(perKey * 40, total * 3 / 10);
    }

    function test_claimShareTwiceReverts() public {
        _buy(alice, 3);
        vm.warp(clock.end());
        clock.settle();
        vm.prank(alice);
        clock.claimShare(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.AlreadyClaimed.selector, 1, alice));
        clock.claimShare(1);
    }

    function test_claimShareFailures() public {
        _buy(alice, 3);
        // Not settled yet.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.RoundNotSettled.selector, 1));
        clock.claimShare(1);
        // Unknown round.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.RoundNotSettled.selector, 7));
        clock.claimShare(7);

        vm.warp(clock.end());
        clock.settle();
        // No keys.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DoomsdayClock.NoKeys.selector, 1, bob));
        clock.claimShare(1);
    }

    function test_withdrawWithNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(DoomsdayClock.NothingToWithdraw.selector);
        clock.withdraw();
    }

    function test_withdrawTwicePaysOnce() public {
        _buy(alice, 1);
        vm.warp(clock.end());
        clock.settle();
        vm.prank(alice);
        clock.withdraw();
        vm.prank(alice);
        vm.expectRevert(DoomsdayClock.NothingToWithdraw.selector);
        clock.withdraw();
    }

    function test_singleHolderOfEveryKey() public {
        uint256 cost = _buy(alice, 100);
        cost += _buy(alice, 100);
        uint256 keys = 200;
        vm.warp(clock.end());
        clock.settle();

        uint256 prize = cost / 2;
        uint256 perKey = (cost * 3 / 10) / keys;
        uint256 carry = cost - prize - perKey * keys;

        vm.prank(alice);
        clock.claimShare(1);
        assertEq(clock.withdrawable(alice), prize + perKey * keys);
        assertEq(clock.carry(), carry);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        clock.withdraw();
        assertEq(token.balanceOf(alice), before + prize + perKey * keys);
        // Everything she paid minus the carry came back.
        assertEq(token.balanceOf(alice), FUND - carry);
        assertEq(token.balanceOf(address(clock)), carry);
        assertLe(perKey * keys, cost * 3 / 10);
        assertGe(carry, cost * 2 / 10);
    }

    function test_carryFlowsAcrossRounds() public {
        // Round 1
        uint256 c1 = _buy(alice, 10);
        vm.warp(clock.end());
        clock.settle();
        uint256 carry1 = clock.carry();
        assertEq(carry1, c1 - c1 / 2 - ((c1 * 3 / 10) / 10) * 10);

        // Round 2 opens with the carry in the pot.
        uint256 c2 = _buy(bob, 4);
        assertEq(clock.carry(), 0);
        assertEq(clock.pot(), carry1 + c2);
        vm.warp(clock.end());
        clock.settle();
        uint256 pot2 = carry1 + c2;
        uint256 perKey2 = (pot2 * 3 / 10) / 4;
        uint256 carry2 = pot2 - pot2 / 2 - perKey2 * 4;
        assertEq(clock.carry(), carry2);
        assertEq(clock.withdrawable(bob), pot2 / 2);
        assertEq(clock.roundInfo(2).perKey, perKey2);

        // Old-round claims still work after later rounds.
        vm.prank(alice);
        assertEq(clock.claimShare(1), ((c1 * 3 / 10) / 10) * 10);

        // Conservation across everything.
        uint256 owed =
            clock.pot() + clock.carry() + clock.withdrawable(alice) + clock.withdrawable(bob) + clock.claimable(2, bob);
        assertEq(token.balanceOf(address(clock)), owed);
    }

    function test_conservationAfterMixedActivity() public {
        _buy(alice, 7);
        _buy(bob, 13);
        vm.warp(clock.end());
        _buy(carol, 1); // settles round 1, opens round 2
        _buy(alice, 50);
        vm.prank(bob);
        clock.claimShare(1);
        vm.prank(bob);
        clock.withdraw();
        vm.warp(clock.end());
        clock.settle();
        vm.prank(alice);
        clock.claimShare(2);

        uint256 unclaimed = clock.claimable(1, alice) + clock.claimable(2, carol);
        uint256 credited = clock.withdrawable(alice) + clock.withdrawable(bob) + clock.withdrawable(carol);
        assertEq(token.balanceOf(address(clock)), clock.pot() + clock.carry() + unclaimed + credited);
    }
}
