// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DoomsdayClock} from "../src/DoomsdayClock.sol";

/// @notice Local / dev-net deployment helper.
/// @dev The Sepolia launch goes through the project factory driven by launch.json, not this
/// script. This exists so a reviewer can stand the pair up on a local anvil. It reads no
/// environment variables; the token address is passed as a function argument.
contract Deploy is Script {
    function deployToken() public returns (LaunchToken) {
        return new LaunchToken();
    }

    function deployClock(address token) public returns (DoomsdayClock) {
        return new DoomsdayClock(token);
    }

    function run() external returns (LaunchToken token, DoomsdayClock clock) {
        vm.startBroadcast();
        token = deployToken();
        clock = deployClock(address(token));
        vm.stopBroadcast();
    }
}
