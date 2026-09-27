// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

contract DeployTest is Test {
    function test_deployFunctionsWireTokenIntoClock() public {
        Deploy d = new Deploy();
        LaunchToken token = d.deployToken();
        DoomsdayClock clock = d.deployClock(address(token));

        assertEq(clock.token(), address(token));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(d)), 1e27, "minted to whoever deployed it");
        assertEq(token.balanceOf(address(clock)), 0, "clock holds nothing at deploy");
    }
}
