// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

/// @dev DOOM has no transfer hooks, so this path is unreachable on the real deployment. The
/// test stands in a hooking token to show the guard holds even if the currency could call back.
contract HookToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    constructor() ERC20("Hook", "HOOK") {
        _mint(msg.sender, 1e27);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && msg.sender == target) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

contract DoomsdayClockReentrancyTest is Test {
    HookToken internal token;
    DoomsdayClock internal clock;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new HookToken();
        clock = new DoomsdayClock(address(token));
        token.transfer(alice, 1e24);
        vm.prank(alice);
        token.approve(address(clock), type(uint256).max);

        vm.prank(alice);
        clock.buyKeys(4, type(uint256).max);
        vm.warp(clock.end());
        clock.settle();
        vm.prank(alice);
        clock.claimShare(1);
    }

    function test_withdrawCannotReenterWithdraw() public {
        uint256 owed = clock.withdrawable(alice);
        token.arm(address(clock), abi.encodeCall(DoomsdayClock.withdraw, ()));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        clock.withdraw();
        // Nothing moved.
        assertEq(clock.withdrawable(alice), owed);
        assertEq(token.balanceOf(address(clock)), clock.pot() + clock.carry() + owed);
    }

    function test_withdrawCannotReenterClaimOrBuy() public {
        token.arm(address(clock), abi.encodeCall(DoomsdayClock.claimShare, (1)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        clock.withdraw();

        token.arm(address(clock), abi.encodeCall(DoomsdayClock.buyKeys, (1, type(uint256).max)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        clock.withdraw();
    }

    function test_buyCannotReenterSettleOrBuy() public {
        token.arm(address(clock), abi.encodeCall(DoomsdayClock.buyKeys, (1, type(uint256).max)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        clock.buyKeys(1, type(uint256).max);

        token.arm(address(clock), abi.encodeCall(DoomsdayClock.settle, ()));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        clock.buyKeys(1, type(uint256).max);
    }

    function test_withdrawSucceedsWhenNotAttacked() public {
        uint256 owed = clock.withdrawable(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        clock.withdraw();
        assertEq(token.balanceOf(alice), before + owed);
        assertEq(clock.withdrawable(alice), 0);
    }
}
