// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenVesting} from "../src/TokenVesting.sol";

contract VestingHandler is Test {
    LaunchToken public immutable token;
    TokenVesting public immutable vesting;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xD00D)];
    uint256 public deposited;
    uint256 public paid;
    uint256 public donated;
    uint256 public latestEnd;
    uint256 public created;
    mapping(address beneficiary => uint256) public paidTo;
    mapping(uint256 id => bytes32) public originalTerms;
    mapping(uint256 id => TokenVesting.Schedule) private model;
    mapping(uint256 id => uint256) public paidFor;

    constructor(LaunchToken token_, TokenVesting vesting_) {
        token = token_;
        vesting = vesting_;
    }

    function create(uint256 actorSeed, uint256 rawAmount, uint256 startOffset, uint256 rawDuration, uint256 rawCliff)
        public
    {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 1e24 ? balance : 1e24);
        address creator = actors[actorSeed % actors.length];
        address beneficiary = actors[(actorSeed / actors.length) % actors.length];
        uint256 offset = bound(startOffset / 2, 0, 7 days);
        uint256 start = startOffset % 2 == 0
            ? block.timestamp + offset
            : block.timestamp - (offset < block.timestamp ? offset : block.timestamp);
        uint256 duration = bound(rawDuration, 1, 365 days);
        uint256 cliff = start + bound(rawCliff, 0, duration);
        token.transfer(creator, amount);
        vm.startPrank(creator);
        token.approve(address(vesting), amount);
        uint256 id = vesting.createSchedule(beneficiary, amount, start, cliff, duration);
        vm.stopPrank();
        created++;
        assertEq(id, created);
        deposited += amount;
        originalTerms[id] = keccak256(abi.encode(beneficiary, amount, start, cliff, duration));
        model[id] = TokenVesting.Schedule(beneficiary, amount, 0, start, cliff, duration);
        if (start + duration > latestEnd) latestEnd = start + duration;
    }

    function claim(uint256 seed) external {
        uint256 count = vesting.scheduleCount();
        if (count == 0) return;
        _claim(seed % count + 1);
    }

    function advanceTime(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 60 days));
    }

    function advanceToBoundary(uint256 seed, uint256 phase) external {
        TokenVesting.Schedule memory schedule = model[seed % created + 1];
        uint256[5] memory boundaries = [
            schedule.start,
            schedule.cliff == 0 ? 0 : schedule.cliff - 1,
            schedule.cliff,
            schedule.start + schedule.duration - 1,
            schedule.start + schedule.duration
        ];
        uint256 next = boundaries[phase % boundaries.length];
        if (next > block.timestamp) vm.warp(next);
    }

    function unauthorizedClaim(uint256 seed, uint256 actorSeed) external {
        uint256 id = seed % created + 1;
        address caller = actors[actorSeed % actors.length];
        if (caller == model[id].beneficiary) caller = actors[(actorSeed % actors.length + 1) % actors.length];
        bytes32 beforeState = _stateHash(id, caller);
        vm.expectRevert(TokenVesting.NotBeneficiary.selector);
        vm.prank(caller);
        vesting.claim(id);
        assertEq(_stateHash(id, caller), beforeState, "unauthorized claim changed state");
    }

    function failedFunding(uint256 actorSeed, uint256 rawAmount, bool insufficientBalance) external {
        address caller = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(caller);
        uint256 amount = insufficientBalance ? balance + 1 : bound(rawAmount, 1, 1e24);
        uint256 allowance = insufficientBalance ? amount : amount - 1;
        vm.prank(caller);
        token.approve(address(vesting), allowance);
        bytes32 beforeState = _stateHash(1, caller);
        bytes memory reason = insufficientBalance
            ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, caller, balance, amount)
            : abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(vesting), allowance, amount
            );
        vm.expectRevert(reason);
        vm.prank(caller);
        vesting.createSchedule(caller, amount, block.timestamp, block.timestamp, 1);
        assertEq(_stateHash(1, caller), beforeState, "failed funding changed state");
    }

    function donate(uint256 rawAmount) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 1e20 ? balance : 1e20);
        token.transfer(address(vesting), amount);
        donated += amount;
    }

    function settleAll() external {
        if (latestEnd > vm.getBlockTimestamp()) vm.warp(latestEnd);
        for (uint256 id = 1; id <= vesting.scheduleCount(); ++id) {
            _claim(id);
        }
    }

    function _claim(uint256 id) private {
        // Decide whether a claim MUST succeed using creation inputs and ghost payouts,
        // never the implementation's claimableAmount result.
        uint256 expected = expectedVested(id) - paidFor[id];
        address beneficiary = model[id].beneficiary;
        if (expected == 0) {
            bytes32 beforeState = _stateHash(id, beneficiary);
            vm.expectRevert(TokenVesting.NothingToClaim.selector);
            vm.prank(beneficiary);
            vesting.claim(id);
            assertEq(_stateHash(id, beneficiary), beforeState, "empty claim changed state");
            return;
        }
        uint256 beforeBalance = token.balanceOf(beneficiary);
        uint256 beforeLocked = vesting.totalLocked();
        vm.prank(beneficiary);
        uint256 amount = vesting.claim(id);
        assertEq(amount, expected, "claim differs from earned amount");
        assertEq(token.balanceOf(beneficiary) - beforeBalance, expected, "incorrect recipient credit");
        assertEq(beforeLocked - vesting.totalLocked(), expected, "incorrect liability reduction");
        paid += expected;
        paidFor[id] += expected;
        paidTo[beneficiary] += expected;

        bytes32 settledState = _stateHash(id, beneficiary);
        vm.expectRevert(TokenVesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        vesting.claim(id);
        assertEq(_stateHash(id, beneficiary), settledState, "duplicate claim changed state");
    }

    function expectedVested(uint256 id) public view returns (uint256) {
        TokenVesting.Schedule memory schedule = model[id];
        if (block.timestamp < schedule.cliff) return 0;
        uint256 elapsed = block.timestamp - schedule.start;
        if (elapsed >= schedule.duration) return schedule.amount;
        // Handler bounds make ordinary multiplication safe; no shared Math.mulDiv oracle.
        return schedule.amount * elapsed / schedule.duration;
    }

    function _stateHash(uint256 id, address caller) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vesting.getSchedule(id),
                vesting.scheduleCount(),
                vesting.totalLocked(),
                token.balanceOf(address(vesting)),
                token.balanceOf(caller),
                token.balanceOf(model[id].beneficiary),
                token.allowance(caller, address(vesting))
            )
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenVestingInvariantTest is Test {
    LaunchToken private token;
    TokenVesting private vesting;
    VestingHandler private handler;

    function setUp() public {
        vm.warp(10_000);
        token = new LaunchToken();
        vesting = new TokenVesting(address(token));
        handler = new VestingHandler(token, vesting);
        token.transfer(address(handler), token.totalSupply());
        // Seed live obligations so every sequence can exercise claim rejection and funding failure.
        handler.create(4, 997, 0, 100, 50);
        handler.create(9, 1, 2, 1, 1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VestingHandler.create.selector;
        selectors[1] = VestingHandler.claim.selector;
        selectors[2] = VestingHandler.advanceTime.selector;
        selectors[3] = VestingHandler.donate.selector;
        selectors[4] = VestingHandler.unauthorizedClaim.selector;
        selectors[5] = VestingHandler.failedFunding.selector;
        selectors[6] = VestingHandler.advanceToBoundary.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantSchedulesAreImmutableAndFullyBacked() public view {
        uint256 outstanding;
        uint256 claimed;
        assertEq(vesting.scheduleCount(), handler.created());
        for (uint256 id = 1; id <= vesting.scheduleCount(); ++id) {
            TokenVesting.Schedule memory schedule = vesting.getSchedule(id);
            assertEq(
                keccak256(
                    abi.encode(schedule.beneficiary, schedule.amount, schedule.start, schedule.cliff, schedule.duration)
                ),
                handler.originalTerms(id)
            );
            uint256 vested = handler.expectedVested(id);
            assertEq(schedule.claimed, handler.paidFor(id));
            assertEq(vesting.vestedAmount(id, block.timestamp), vested);
            assertLe(schedule.claimed, vested);
            assertLe(vested, schedule.amount);
            assertEq(vesting.claimableAmount(id), vested - schedule.claimed);
            outstanding += schedule.amount - schedule.claimed;
            claimed += schedule.claimed;
        }
        assertEq(claimed, handler.paid());
        assertEq(vesting.totalLocked(), outstanding);
        assertEq(outstanding + claimed, handler.deposited());
        assertEq(token.balanceOf(address(vesting)), outstanding + handler.donated());
        assertEq(token.balanceOf(address(handler)) + handler.deposited() + handler.donated(), 1e27);
        for (uint256 i; i < 4; ++i) {
            address beneficiary = handler.actors(i);
            assertEq(token.balanceOf(beneficiary), handler.paidTo(beneficiary));
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.settleAll();
        assertEq(vesting.totalLocked(), 0);
        assertEq(token.balanceOf(address(vesting)), handler.donated());
        assertEq(handler.paid(), handler.deposited());
        invariantSchedulesAreImmutableAndFullyBacked();
    }
}
