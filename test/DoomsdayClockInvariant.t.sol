// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

/// @dev Drives the game with a fixed set of funded players. Every action is guarded so the
/// handler never reverts; the invariant checks the accounting, not the handler.
contract ClockHandler is Test {
    LaunchToken public token;
    DoomsdayClock public clock;
    address[] public actors;

    // Ghost accounting.
    mapping(uint256 => uint256) public claimedOf; // DOOM credited from claims per round
    uint256 public totalPaidIn;
    uint256 public totalPaidOut;
    uint256 public settlements;
    uint256 public claims;
    uint256 public buys;
    uint256 public withdrawals;

    constructor(LaunchToken token_, DoomsdayClock clock_, address[] memory actors_) {
        token = token_;
        clock = clock_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 actorSeed, uint256 n, uint256 delay) external {
        n = bound(n, 1, 100);
        delay = bound(delay, 0, 2 hours);
        vm.warp(block.timestamp + delay);
        address who = _actor(actorSeed);
        uint256 cost = clock.priceOfNext(n);
        if (token.balanceOf(who) < cost) return;
        if (clock.hasEnded()) settlements++;
        vm.prank(who);
        uint256 paid = clock.buyKeys(n, cost);
        assertEq(paid, cost, "quote must match payment");
        totalPaidIn += paid;
        buys++;
    }

    function settle(uint256 delay) external {
        delay = bound(delay, 0, 26 hours);
        vm.warp(block.timestamp + delay);
        if (!clock.hasEnded()) return;
        clock.settle();
        settlements++;
    }

    function claim(uint256 actorSeed, uint256 roundSeed) external {
        uint256 current = clock.round();
        if (current < 2) return;
        uint256 id = 1 + (roundSeed % (current - 1));
        address who = _actor(actorSeed);
        if (clock.claimable(id, who) == 0) return;
        vm.prank(who);
        uint256 amount = clock.claimShare(id);
        claimedOf[id] += amount;
        claims++;
    }

    function withdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 owed = clock.withdrawable(who);
        if (owed == 0) return;
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        uint256 paid = clock.withdraw();
        assertEq(paid, owed);
        assertEq(token.balanceOf(who), before + owed);
        totalPaidOut += paid;
        withdrawals++;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract DoomsdayClockInvariantTest is Test {
    LaunchToken internal token;
    DoomsdayClock internal clock;
    ClockHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new LaunchToken();
        clock = new DoomsdayClock(address(token));

        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string.concat("player", vm.toString(i)));
            actors.push(a);
            token.transfer(a, 100_000_000 * 1e18);
            vm.prank(a);
            token.approve(address(clock), type(uint256).max);
        }

        handler = new ClockHandler(token, clock, actors);
        targetContract(address(handler));
    }

    /// @dev DOOM held == current pot + carry + unclaimed shares + withdrawable balances.
    function invariant_conservation() public view {
        uint256 current = clock.round();
        uint256 unclaimed;
        for (uint256 id = 1; id < current; ++id) {
            DoomsdayClock.Round memory r = clock.roundInfo(id);
            assertTrue(r.settled, "every past round is settled");
            unclaimed += r.perKey * r.totalKeys - handler.claimedOf(id);
        }
        uint256 credited;
        for (uint256 i; i < actors.length; ++i) {
            credited += clock.withdrawable(actors[i]);
        }
        assertEq(token.balanceOf(address(clock)), clock.pot() + clock.carry() + unclaimed + credited);
        assertEq(token.balanceOf(address(clock)), handler.totalPaidIn() - handler.totalPaidOut());
    }

    /// @dev Settled rounds never hand out more than their pot, and shares stay within 30%.
    function invariant_settledRoundsRespectSplits() public view {
        uint256 current = clock.round();
        for (uint256 id = 1; id < current; ++id) {
            DoomsdayClock.Round memory r = clock.roundInfo(id);
            uint256 shares = r.perKey * r.totalKeys;
            assertLe(shares, r.pot * 3 / 10, "shares exceed 30%");
            assertLe(r.pot / 2 + shares, r.pot, "payout exceeds pot");
            assertGt(r.totalKeys, 0, "settled round had keys");
            assertTrue(r.lastBuyer != address(0), "settled round had a buyer");
        }
    }

    /// @dev The timer never points more than 24 hours ahead.
    function invariant_endWithinCap() public view {
        uint256 e = clock.end();
        if (e != 0) assertLe(e, block.timestamp + 24 hours);
        assertEq(address(clock).balance, 0);
    }
}
