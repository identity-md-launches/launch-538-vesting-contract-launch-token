// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function testFixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Launch Token");
        assertEq(token.symbol(), "TOKEN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testTransferMovesExactAmount() public {
        assertTrue(token.transfer(ALICE, 123 ether));
        assertEq(token.balanceOf(ALICE), 123 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 123 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function testTransferFromConsumesAllowance() public {
        token.approve(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 60 ether));
        assertEq(token.allowance(address(this), ALICE), 40 ether);
        assertEq(token.balanceOf(BOB), 60 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 60 ether);
    }

    function testRejectsInsufficientBalanceAndAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);

        token.approve(ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 1, 2));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 2);
        assertEq(token.allowance(address(this), ALICE), 1);
    }

    function testRejectsZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testNoMintOrAdministrationEvenForDeployer() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("burn(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzzTransfersConserveSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 1e27);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(BOB), token.totalSupply());
    }
}
