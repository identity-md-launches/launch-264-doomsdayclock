// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Doomsday");
        assertEq(token.symbol(), "DOOM");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsFixedAndMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 123e18));
        assertEq(token.balanceOf(alice), 123e18);
        assertEq(token.balanceOf(deployer), 1e27 - 123e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferRevertsWithoutBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.approve(alice, 5e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_noMintOrAdminSelectors() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
