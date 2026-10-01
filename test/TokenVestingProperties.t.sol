// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {TokenVesting} from "src/TokenVesting.sol";

/// forge-config: default.fuzz.runs = 1000
contract TokenVestingPropertiesTest is Test {
    LaunchToken private token;
    TokenVesting private vesting;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SUPPLY = 1e27;

    function setUp() public {
        vm.warp(1_000);
        token = new LaunchToken();
        vesting = new TokenVesting(address(token));
        token.approve(address(vesting), type(uint256).max);
    }

    // Construct duration = scale * denominator and elapsed = scale * numerator.
    // The exact answer cancels scale, so the oracle needs no 512-bit mulDiv even
    // when the production multiplication overflows 256 bits before division.
    function testFuzzScaledTimeFractions(
        uint256 amount,
        uint256 scale,
        uint256 denominator,
        uint256 numerator,
        uint256 start
    ) public {
        amount = bound(amount, 1, SUPPLY);
        denominator = bound(denominator, 1, 1_000_000);
        numerator = bound(numerator, 0, denominator);
        scale = bound(scale, 1, type(uint256).max / denominator);
        uint256 duration = scale * denominator;
        start = bound(start, 0, type(uint256).max - duration);
        uint256 id = vesting.createSchedule(ALICE, amount, start, start, duration);
        uint256 expected = amount * numerator / denominator;

        vm.warp(start + scale * numerator);
        assertEq(vesting.vestedAmount(id, block.timestamp), expected);
        _claimExpected(id, ALICE, expected);
        assertEq(token.balanceOf(ALICE), expected);
        assertEq(vesting.totalLocked(), amount - expected);

        vm.warp(start + duration);
        _claimExpected(id, ALICE, amount - expected);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    // Moving every timestamp by the same offset must preserve entitlement,
    // including before the cliff and at the largest representable end time.
    function testFuzzTimeTranslationPreservesEntitlement(
        uint256 amount,
        uint256 duration,
        uint256 offset,
        uint256 cliff,
        uint256 elapsed
    ) public {
        amount = bound(amount, 1, SUPPLY / 2);
        duration = bound(duration, 1, type(uint256).max);
        offset = bound(offset, 0, type(uint256).max - duration);
        cliff = bound(cliff, 0, duration);
        elapsed = bound(elapsed, 0, duration);
        uint256 base = vesting.createSchedule(ALICE, amount, 0, cliff, duration);
        uint256 shifted = vesting.createSchedule(BOB, amount, offset, offset + cliff, duration);
        assertEq(vesting.vestedAmount(base, elapsed), vesting.vestedAmount(shifted, offset + elapsed));
        assertEq(vesting.vestedAmount(base, duration), amount);
        assertEq(vesting.vestedAmount(shifted, offset + duration), amount);
        assertLe(vesting.vestedAmount(base, elapsed / 2), vesting.vestedAmount(base, elapsed));
        if (cliff > 0) {
            assertEq(vesting.vestedAmount(shifted, offset + cliff - 1), 0);
        }
    }

    function testFuzzSplittingDepositCannotAcceleratePayout(
        uint256 firstAmount,
        uint256 secondAmount,
        uint256 duration,
        uint256 cliff,
        uint256 elapsed
    ) public {
        firstAmount = bound(firstAmount, 1, SUPPLY / 4);
        secondAmount = bound(secondAmount, 1, SUPPLY / 4);
        duration = bound(duration, 1, 3650 days);
        cliff = bound(cliff, 0, duration);
        elapsed = bound(elapsed, 0, duration);
        uint256 combined = vesting.createSchedule(ALICE, firstAmount + secondAmount, 1_000, 1_000 + cliff, duration);
        uint256 first = vesting.createSchedule(BOB, firstAmount, 1_000, 1_000 + cliff, duration);
        uint256 second = vesting.createSchedule(BOB, secondAmount, 1_000, 1_000 + cliff, duration);

        vm.warp(1_000 + elapsed);
        // Integer division leaves at most one extra unit of dust when splitting in two.
        uint256 whole = vesting.vestedAmount(combined, block.timestamp);
        uint256 pieces = vesting.vestedAmount(first, block.timestamp) + vesting.vestedAmount(second, block.timestamp);
        assertLe(pieces, whole);
        assertLe(whole - pieces, 1);
        _claimExpected(combined, ALICE, whole);
        _claimExpected(first, BOB, vesting.vestedAmount(first, block.timestamp));
        _claimExpected(second, BOB, vesting.vestedAmount(second, block.timestamp));
        assertEq(token.balanceOf(ALICE), whole);
        assertEq(token.balanceOf(BOB), pieces);

        vm.warp(1_000 + duration);
        _claimExpected(combined, ALICE, firstAmount + secondAmount - whole);
        _claimExpected(first, BOB, firstAmount - vesting.getSchedule(first).claimed);
        _claimExpected(second, BOB, secondAmount - vesting.getSchedule(second).claimed);
        assertEq(token.balanceOf(ALICE), firstAmount + secondAmount);
        assertEq(token.balanceOf(BOB), firstAmount + secondAmount);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testFullSupplyAtMaximumDurationReleasesEveryUnit() public {
        uint256 id = vesting.createSchedule(ALICE, SUPPLY, 0, 0, type(uint256).max);
        vm.warp(type(uint256).max / 2);
        _claimExpected(id, ALICE, SUPPLY / 2 - 1);
        vm.warp(type(uint256).max - 1);
        _claimExpected(id, ALICE, SUPPLY / 2);
        vm.warp(type(uint256).max);
        _claimExpected(id, ALICE, 1);
        _claimExpected(id, ALICE, 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.totalLocked(), 0);
    }

    function testOneWeiAtMaximumStartAndEnd() public {
        uint256 start = type(uint256).max - 1;
        uint256 id = vesting.createSchedule(ALICE, 1, start, start, 1);
        vm.warp(start);
        _claimExpected(id, ALICE, 0);
        vm.warp(type(uint256).max);
        _claimExpected(id, ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(vesting.totalLocked(), 0);
    }

    function testRevokingApprovalCannotRevokeFundedObligations() public {
        uint256 id = vesting.createSchedule(ALICE, SUPPLY, 1_000, 1_010, 100);
        token.approve(address(vesting), 0);
        assertEq(token.balanceOf(address(this)), 0);
        vm.warp(1_010);
        _claimExpected(id, ALICE, SUPPLY / 10);
        vm.warp(1_100);
        _claimExpected(id, ALICE, SUPPLY - SUPPLY / 10);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(vesting.totalLocked(), 0);
    }

    function testFuzzUnknownIdsCannotAccessLiveSchedules(uint256 id) public {
        _seedPartialClaim();
        id = bound(id, 2, type(uint256).max);
        bytes32 beforeState = _stateHash();
        bytes memory errorData = abi.encodeWithSelector(TokenVesting.UnknownSchedule.selector, id);
        vm.expectRevert(errorData);
        vesting.getSchedule(id);
        vm.expectRevert(errorData);
        vesting.vestedAmount(id, type(uint256).max);
        vm.expectRevert(errorData);
        vesting.claimableAmount(id);
        vm.expectRevert(errorData);
        vm.prank(ALICE);
        vesting.claim(id);
        assertEq(_stateHash(), beforeState);
    }

    function testFuzzInvalidCreationPreservesLiveSchedules(
        uint256 kind,
        uint256 amount,
        uint256 start,
        uint256 duration
    ) public {
        _seedPartialClaim();
        amount = bound(amount, 1, token.balanceOf(address(this)));
        duration = bound(duration, 1, type(uint256).max - 1);
        start = bound(start, 1, type(uint256).max - duration);
        uint256 cliff = start;
        address beneficiary = BOB;
        bytes4 expectedError = TokenVesting.InvalidTiming.selector;
        kind %= 7;
        if (kind == 0 || kind == 1) {
            beneficiary = kind == 0 ? address(0) : address(vesting);
            expectedError = TokenVesting.InvalidBeneficiary.selector;
        } else if (kind == 2) {
            amount = 0;
            expectedError = TokenVesting.ZeroAmount.selector;
        } else if (kind == 3) {
            duration = 0;
        } else if (kind == 4) {
            cliff = start - 1;
        } else if (kind == 5) {
            // Keep the end below max so an invalid cliff above it is representable.
            start = 0;
            cliff = duration + 1;
        } else {
            start = type(uint256).max - duration + 1;
            cliff = start;
        }
        // A finite approval also detects accidental consumption on failed validation.
        token.approve(address(vesting), SUPPLY / 2);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(expectedError);
        vesting.createSchedule(beneficiary, amount, start, cliff, duration);
        assertEq(_stateHash(), beforeState, "rejected creation altered live state");

        uint256 next = vesting.createSchedule(BOB, 1, 0, 0, 1);
        assertEq(next, 2, "failed creation consumed an ID");
        _claimExpected(next, BOB, 1);
        vm.warp(1_100);
        _claimExpected(1, ALICE, 750);
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), 17, "donation was spent");
    }

    function _seedPartialClaim() private {
        vesting.createSchedule(ALICE, 1_000, 1_000, 1_000, 100);
        token.transfer(address(vesting), 17);
        vm.warp(1_025);
        _claimExpected(1, ALICE, 250);
    }

    function _claimExpected(uint256 id, address beneficiary, uint256 expected) private {
        assertEq(vesting.claimableAmount(id), expected);
        uint256 beforeBalance = token.balanceOf(beneficiary);
        uint256 beforeClaimed = vesting.getSchedule(id).claimed;
        uint256 beforeLocked = vesting.totalLocked();
        if (expected == 0) vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        uint256 actual = vesting.claim(id);
        if (expected > 0) assertEq(actual, expected);
        assertEq(token.balanceOf(beneficiary), beforeBalance + expected);
        assertEq(vesting.getSchedule(id).claimed, beforeClaimed + expected);
        assertEq(vesting.totalLocked(), beforeLocked - expected);
    }

    function _stateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vesting.getSchedule(1),
                vesting.scheduleCount(),
                vesting.totalLocked(),
                token.balanceOf(address(this)),
                token.balanceOf(address(vesting)),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.allowance(address(this), address(vesting))
            )
        );
    }
}
