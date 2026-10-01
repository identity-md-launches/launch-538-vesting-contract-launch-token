// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {AdversarialToken} from "./mocks/AdversarialToken.sol";

contract TokenVestingAdversarialTest is Test {
    AdversarialToken private token;
    TokenVesting private vesting;
    address private constant ALICE = address(0xA11CE);
    uint256 private constant AMOUNT = 1_000;

    function setUp() public {
        vm.warp(1_000);
        token = new AdversarialToken();
        vesting = new TokenVesting(address(token));
        token.mint(address(this), 10_000);
        token.approve(address(vesting), 10_000);
    }

    function testFalseReturningDepositRollsBackTokenAndScheduleState() public {
        token.setModes(AdversarialToken.Mode.ReturnFalse, AdversarialToken.Mode.Normal);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _create(ALICE);
        _assertNoDeposit();
    }

    function testRevertingDepositCreatesNoSchedule() public {
        token.setModes(AdversarialToken.Mode.Revert, AdversarialToken.Mode.Normal);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        _create(ALICE);
        _assertNoDeposit();
    }

    function testFeeDepositRejectedEvenWhenDonationsCoverShortfall() public {
        token.transfer(address(vesting), 100);
        token.setModes(AdversarialToken.Mode.Fee, AdversarialToken.Mode.Normal);
        vm.expectRevert(TokenVesting.InexactDeposit.selector);
        _create(ALICE);
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 100);
        assertEq(token.balanceOf(address(this)), 9_900);
        assertEq(token.totalSupply(), 10_000);
    }

    function testTokenReturningTrueWithoutFundingIsRejected() public {
        token.setModes(AdversarialToken.Mode.NoMovement, AdversarialToken.Mode.Normal);
        vm.expectRevert(TokenVesting.InexactDeposit.selector);
        _create(ALICE);
        _assertNoDeposit();
    }

    function testNoReturnTokenCanFundAndPay() public {
        token.setModes(AdversarialToken.Mode.NoReturn, AdversarialToken.Mode.NoReturn);
        uint256 id = _create(ALICE);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), AMOUNT);
        assertEq(token.balanceOf(ALICE), AMOUNT);
        assertEq(vesting.totalLocked(), 0);
    }

    function testFalseReturningPayoutRollsBackAndCanBeRetried() public {
        uint256 id = _create(ALICE);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        vesting.claim(id);
        _assertUnclaimed(id);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), AMOUNT);
        assertEq(token.balanceOf(ALICE), AMOUNT);
    }

    function testRevertingPayoutDoesNotConsumeClaim() public {
        uint256 id = _create(ALICE);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Revert);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        vm.prank(ALICE);
        vesting.claim(id);
        _assertUnclaimed(id);
    }

    function testDepositCannotReenterCreation() public {
        token.mint(address(token), AMOUNT);
        token.approveFromToken(address(vesting), AMOUNT);
        token.setCallback(address(vesting), abi.encodeCall(TokenVesting.createSchedule, (ALICE, AMOUNT, 0, 0, 1)));
        token.setModes(AdversarialToken.Mode.Reenter, AdversarialToken.Mode.Normal);
        assertEq(_create(ALICE), 1);
        _assertReentryBlocked();
        assertEq(vesting.scheduleCount(), 1);
        assertEq(vesting.totalLocked(), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
    }

    function testDepositCannotReenterClaim() public {
        uint256 prior = _create(address(token));
        token.setCallback(address(vesting), abi.encodeCall(TokenVesting.claim, (prior)));
        token.setModes(AdversarialToken.Mode.Reenter, AdversarialToken.Mode.Normal);
        _create(ALICE);
        _assertReentryBlocked();
        assertEq(vesting.getSchedule(prior).claimed, 0);
        assertEq(vesting.totalLocked(), 2 * AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 2 * AMOUNT);
    }

    function testPayoutCannotReenterClaimOrDoubleSpend() public {
        uint256 id = _create(address(token));
        token.setCallback(address(vesting), abi.encodeCall(TokenVesting.claim, (id)));
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Reenter);
        assertEq(token.claimFromToken(vesting, id), AMOUNT);
        _assertReentryBlocked();
        assertEq(vesting.getSchedule(id).claimed, AMOUNT);
        assertEq(token.balanceOf(address(token)), AMOUNT);
        assertEq(vesting.totalLocked(), 0);
    }

    function testPayoutCannotReenterCreation() public {
        uint256 id = _create(address(token));
        token.approveFromToken(address(vesting), AMOUNT);
        token.setCallback(address(vesting), abi.encodeCall(TokenVesting.createSchedule, (ALICE, AMOUNT, 0, 0, 1)));
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Reenter);
        token.claimFromToken(vesting, id);
        _assertReentryBlocked();
        assertEq(vesting.scheduleCount(), 1);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(token)), AMOUNT);
    }

    function testFullPrecisionArithmeticHandlesMaximumAmount() public {
        AdversarialToken largeToken = new AdversarialToken();
        TokenVesting largeVesting = new TokenVesting(address(largeToken));
        largeToken.mint(address(this), type(uint256).max);
        largeToken.approve(address(largeVesting), type(uint256).max);
        uint256 id = largeVesting.createSchedule(ALICE, type(uint256).max, 1_000, 1_000, 4);
        vm.warp(1_002);
        vm.prank(ALICE);
        assertEq(largeVesting.claim(id), type(uint256).max / 2);
        vm.warp(1_004);
        vm.prank(ALICE);
        assertEq(largeVesting.claim(id), type(uint256).max - type(uint256).max / 2);
        assertEq(largeToken.balanceOf(ALICE), type(uint256).max);
        assertEq(largeVesting.totalLocked(), 0);
    }

    function _create(address beneficiary) private returns (uint256) {
        return vesting.createSchedule(beneficiary, AMOUNT, 0, 0, 1);
    }

    function _assertNoDeposit() private view {
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(address(this)), 10_000);
        assertEq(token.allowance(address(this), address(vesting)), 10_000);
    }

    function _assertUnclaimed(uint256 id) private view {
        assertEq(vesting.getSchedule(id).claimed, 0);
        assertEq(vesting.claimableAmount(id), AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function _assertReentryBlocked() private view {
        assertEq(token.callbackCount(), 1);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
