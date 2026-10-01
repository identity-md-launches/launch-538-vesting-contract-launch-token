// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenVesting} from "../src/TokenVesting.sol";

contract TokenVestingTest is Test {
    LaunchToken private token;
    TokenVesting private vesting;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant START = 10_000;
    uint256 private constant CLIFF = 10_200;
    uint256 private constant DURATION = 1_000;
    uint256 private constant AMOUNT = 1_001;

    function setUp() public {
        vm.warp(START - 100);
        token = new LaunchToken();
        vesting = new TokenVesting(address(token));
        token.approve(address(vesting), 1e27);
    }

    function testCreateFundsScheduleAndEmitsDetails() public {
        vm.expectEmit(true, true, true, true, address(vesting));
        emit TokenVesting.ScheduleCreated(1, address(this), ALICE, AMOUNT, START, CLIFF, DURATION);
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(vesting.scheduleCount(), 1);
        assertEq(address(vesting.token()), address(token));
        TokenVesting.Schedule memory schedule = vesting.getSchedule(id);
        assertEq(schedule.beneficiary, ALICE);
        assertEq(schedule.amount, AMOUNT);
        assertEq(schedule.claimed, 0);
        assertEq(schedule.start, START);
        assertEq(schedule.cliff, CLIFF);
        assertEq(schedule.duration, DURATION);
        assertEq(token.balanceOf(address(this)), 1e27 - AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
    }

    function testAnyoneCanFundMultipleSchedulesForSameBeneficiary() public {
        _create();
        token.transfer(BOB, 300);
        vm.startPrank(BOB);
        token.approve(address(vesting), 300);
        uint256 id = vesting.createSchedule(ALICE, 300, START, START, 30);
        vm.stopPrank();
        assertEq(id, 2);
        assertEq(vesting.getSchedule(1).amount, AMOUNT);
        assertEq(vesting.getSchedule(2).amount, 300);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(vesting.totalLocked(), AMOUNT + 300);
    }

    function testCliffAndEndBoundaries() public {
        uint256 id = _create();
        assertEq(vesting.vestedAmount(id, 0), 0);
        assertEq(vesting.vestedAmount(id, START - 1), 0);
        assertEq(vesting.vestedAmount(id, START), 0);
        assertEq(vesting.vestedAmount(id, CLIFF - 1), 0);
        assertEq(vesting.vestedAmount(id, CLIFF), 200);
        assertEq(vesting.vestedAmount(id, START + 500), 500);
        assertEq(vesting.vestedAmount(id, START + DURATION - 1), 999);
        assertEq(vesting.vestedAmount(id, START + DURATION), AMOUNT);
        assertEq(vesting.vestedAmount(id, type(uint256).max), AMOUNT);
    }

    function testBeneficiaryClaimsAccruedAtCliffThenOnlyIncrementThenDust() public {
        uint256 id = _create();
        vm.warp(CLIFF);
        vm.expectEmit(true, true, false, true, address(vesting));
        emit TokenVesting.Claimed(id, ALICE, 200);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), 200);
        assertEq(vesting.getSchedule(id).claimed, 200);
        assertEq(vesting.claimableAmount(id), 0);
        assertEq(vesting.totalLocked(), 801);

        vm.warp(START + 500);
        assertEq(vesting.claimableAmount(id), 300);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), 300);

        vm.warp(START + DURATION - 1);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), 499);

        vm.warp(START + DURATION);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), 2);
        assertEq(token.balanceOf(ALICE), AMOUNT);
        assertEq(vesting.getSchedule(id).claimed, AMOUNT);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.vestedAmount(id, CLIFF), 200);
        vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(ALICE);
        vesting.claim(id);
    }

    function testRejectsEarlyAndDuplicateClaims() public {
        uint256 id = _create();
        vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(ALICE);
        vesting.claim(id);
        vm.warp(CLIFF - 1);
        vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(ALICE);
        vesting.claim(id);
        vm.warp(CLIFF);
        vm.prank(ALICE);
        vesting.claim(id);
        vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(ALICE);
        vesting.claim(id);
        assertEq(token.balanceOf(ALICE), 200);
    }

    function testOnlyBeneficiaryCanClaimIncludingAgainstCreator() public {
        uint256 id = _create();
        vm.warp(START + DURATION);
        vm.expectRevert(TokenVesting.NotBeneficiary.selector);
        vesting.claim(id);
        vm.expectRevert(TokenVesting.NotBeneficiary.selector);
        vm.prank(BOB);
        vesting.claim(id);
        assertEq(vesting.getSchedule(id).claimed, 0);
        assertEq(vesting.totalLocked(), AMOUNT);
    }

    function testNoCliffAndOneSecondDuration() public {
        uint256 id = vesting.createSchedule(ALICE, 1, START, START, 1);
        vm.warp(START);
        assertEq(vesting.claimableAmount(id), 0);
        vm.warp(START + 1);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), 1);
    }

    function testCliffAtEndLocksEntireAmountUntilEnd() public {
        uint256 id = vesting.createSchedule(ALICE, AMOUNT, START, START + DURATION, DURATION);
        vm.warp(START + DURATION - 1);
        assertEq(vesting.claimableAmount(id), 0);
        vm.warp(START + DURATION);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), AMOUNT);
    }

    function testPastStartAccruesImmediatelyAndExpiredScheduleIsAllowed() public {
        vm.warp(START + 500);
        uint256 id = _create();
        assertEq(vesting.claimableAmount(id), 500);
        vm.warp(START + DURATION + 10);
        uint256 expired = _create();
        vm.prank(ALICE);
        assertEq(vesting.claim(expired), AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
    }

    function testSeparateSchedulesCannotSpendEachOthersFunds() public {
        uint256 aliceId = _create();
        uint256 bobId = vesting.createSchedule(BOB, 777, START, START, 10);
        vm.warp(START + 10);
        vm.prank(BOB);
        vesting.claim(bobId);
        assertEq(token.balanceOf(BOB), 777);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
        vm.warp(START + DURATION);
        vm.prank(ALICE);
        vesting.claim(aliceId);
        assertEq(token.balanceOf(ALICE), AMOUNT);
        assertEq(vesting.totalLocked(), 0);
    }

    function testDonationsCreateNoClaimAndRemainAfterSettlement() public {
        token.transfer(address(vesting), 55);
        uint256 id = _create();
        assertEq(vesting.totalLocked(), AMOUNT);
        vm.warp(START + DURATION);
        vm.prank(ALICE);
        vesting.claim(id);
        assertEq(token.balanceOf(address(vesting)), 55);
        assertEq(vesting.totalLocked(), 0);
    }

    function testRejectsInvalidTokenAddresses() public {
        vm.expectRevert(TokenVesting.InvalidToken.selector);
        new TokenVesting(address(0));
        vm.expectRevert(TokenVesting.InvalidToken.selector);
        new TokenVesting(ALICE);
    }

    function testRejectsInvalidBeneficiariesAndZeroAmount() public {
        vm.expectRevert(TokenVesting.InvalidBeneficiary.selector);
        vesting.createSchedule(address(0), AMOUNT, START, CLIFF, DURATION);
        vm.expectRevert(TokenVesting.InvalidBeneficiary.selector);
        vesting.createSchedule(address(vesting), AMOUNT, START, CLIFF, DURATION);
        vm.expectRevert(TokenVesting.ZeroAmount.selector);
        vesting.createSchedule(ALICE, 0, START, CLIFF, DURATION);
        assertEq(vesting.scheduleCount(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testRejectsZeroDurationInvalidCliffAndEndOverflow() public {
        vm.expectRevert(TokenVesting.InvalidTiming.selector);
        vesting.createSchedule(ALICE, AMOUNT, START, START, 0);
        vm.expectRevert(TokenVesting.InvalidTiming.selector);
        vesting.createSchedule(ALICE, AMOUNT, START, START - 1, DURATION);
        vm.expectRevert(TokenVesting.InvalidTiming.selector);
        vesting.createSchedule(ALICE, AMOUNT, START, START + DURATION + 1, DURATION);
        vm.expectRevert(TokenVesting.InvalidTiming.selector);
        vesting.createSchedule(ALICE, AMOUNT, type(uint256).max, type(uint256).max, 1);
        assertEq(vesting.scheduleCount(), 0);
    }

    function testLargestValidEndAndZeroStart() public {
        uint256 id = vesting.createSchedule(ALICE, AMOUNT, 0, 0, type(uint256).max);
        assertEq(vesting.vestedAmount(id, 0), 0);
        assertEq(vesting.vestedAmount(id, type(uint256).max / 2), 500);
        assertEq(vesting.vestedAmount(id, type(uint256).max), AMOUNT);
    }

    function testRejectsUnknownScheduleAcrossAllEntryPoints() public {
        _assertUnknown(0);
        _assertUnknown(1);
        _create();
        _assertUnknown(2);
    }

    function testMissingApprovalRollsBackCreation() public {
        token.approve(address(vesting), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vesting), 0, AMOUNT)
        );
        _create();
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.approve(address(vesting), AMOUNT);
        assertEq(_create(), 1);
    }

    function testInsufficientBalanceRollsBackCreationAndAllowance() public {
        vm.startPrank(BOB);
        token.approve(address(vesting), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, AMOUNT));
        vesting.createSchedule(ALICE, AMOUNT, START, CLIFF, DURATION);
        vm.stopPrank();
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.allowance(BOB, address(vesting)), AMOUNT);
    }

    function testCreatorCannotRevokeCancelOrWithdraw() public {
        uint256 id = _create();
        bytes[3] memory calls = [
            abi.encodeWithSignature("revoke(uint256)", id),
            abi.encodeWithSignature("cancelSchedule(uint256)", id),
            abi.encodeWithSignature("withdraw(uint256)", AMOUNT)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(vesting).call(calls[i]);
            assertFalse(success);
        }
        assertEq(vesting.getSchedule(id).amount, AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
        vm.warp(START + DURATION);
        vm.prank(ALICE);
        assertEq(vesting.claim(id), AMOUNT);
    }

    function testFuzzClaimFrequencyPreservesFinalPayout(
        uint96 rawAmount,
        uint32 rawDuration,
        uint32 rawCliff,
        uint32 rawFirst,
        uint32 rawSecond
    ) public {
        uint256 amount = bound(rawAmount, 1, 1e27);
        uint256 duration = bound(rawDuration, 1, 3650 days);
        uint256 cliffOffset = bound(rawCliff, 0, duration);
        uint256 first = bound(rawFirst, 0, duration);
        uint256 second = bound(rawSecond, first, duration);
        uint256 id = vesting.createSchedule(ALICE, amount, START, START + cliffOffset, duration);
        _claimIfAvailable(id, START + first);
        uint256 expectedFirst = first < cliffOffset ? 0 : amount * first / duration;
        assertEq(token.balanceOf(ALICE), expectedFirst);
        _claimIfAvailable(id, START + second);
        uint256 expectedSecond = second < cliffOffset ? 0 : amount * second / duration;
        assertEq(token.balanceOf(ALICE), expectedSecond);
        assertEq(vesting.totalLocked() + token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(vesting)), vesting.totalLocked());
        _claimIfAvailable(id, START + duration);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function _create() private returns (uint256) {
        return vesting.createSchedule(ALICE, AMOUNT, START, CLIFF, DURATION);
    }

    function _assertUnknown(uint256 id) private {
        bytes memory reason = abi.encodeWithSelector(TokenVesting.UnknownSchedule.selector, id);
        vm.expectRevert(reason);
        vesting.getSchedule(id);
        vm.expectRevert(reason);
        vesting.vestedAmount(id, START);
        vm.expectRevert(reason);
        vesting.claimableAmount(id);
        vm.expectRevert(reason);
        vesting.claim(id);
    }

    function _claimIfAvailable(uint256 id, uint256 timestamp) private {
        vm.warp(timestamp);
        if (vesting.claimableAmount(id) > 0) {
            vm.prank(ALICE);
            vesting.claim(id);
        }
    }
}
