// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Doomsday (DOOM) launch token
/// @notice Fixed-supply ERC-20 used as the working currency of DoomsdayClock.
/// @dev The whole supply is minted once to the deployer (the project factory) in the
/// constructor. There is no mint, burn-by-admin, owner, pause, blocklist, fee or upgrade
/// path: the contract is exactly OpenZeppelin ERC20 plus this constructor.
contract LaunchToken is ERC20 {
    /// @notice 1,000,000,000 DOOM with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Doomsday", "DOOM") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
