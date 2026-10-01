// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply launch token. The entire supply belongs to its deployer at creation.
contract LaunchToken is ERC20 {
    constructor() ERC20("Launch Token", "TOKEN") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
