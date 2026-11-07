// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A valueless launch test token. DO NOT BUY.
/// @dev The launch factory receives the entire, final supply and handles all launch allocations.
contract TestToken is ERC20 {
    constructor() ERC20("SIMD TEST 2 - DO NOT BUY", "SIMDTEST2") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
