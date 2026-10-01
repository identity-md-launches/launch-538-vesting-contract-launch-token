// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenVesting} from "../src/TokenVesting.sol";

/// @dev Local factory stand-in: checks constructors without environment variables or broadcasts.
contract DeploymentHarness {
    function deploy() external returns (LaunchToken token, TokenVesting vesting) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        vesting = new TokenVesting{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentTest is Test {
    function testFactoryDeploymentPreservesSupplyAndFullyConfiguresVesting() public {
        DeploymentHarness factory = new DeploymentHarness();
        (LaunchToken token, TokenVesting vesting) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(vesting));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }
}
