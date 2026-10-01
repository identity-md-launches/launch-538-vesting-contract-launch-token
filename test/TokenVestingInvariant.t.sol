// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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

    constructor(LaunchToken token_, TokenVesting vesting_) {
        token = token_;
        vesting = vesting_;
    }

    function create(uint256 actorSeed, uint256 rawAmount, uint256 startOffset, uint256 rawDuration, uint256 rawCliff)
        external
    {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 1e24 ? balance : 1e24);
        address creator = actors[actorSeed % actors.length];
        address beneficiary = actors[(actorSeed / actors.length) % actors.length];
        uint256 start = block.timestamp + bound(startOffset, 0, 7 days);
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

    function donate(uint256 rawAmount) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 1e20 ? balance : 1e20);
        token.transfer(address(vesting), amount);
        donated += amount;
    }

    function settleAll() external {
        if (latestEnd > block.timestamp) vm.warp(latestEnd);
        for (uint256 id = 1; id <= vesting.scheduleCount(); ++id) {
            _claim(id);
        }
    }

    function _claim(uint256 id) private {
        if (vesting.claimableAmount(id) == 0) return;
        address beneficiary = vesting.getSchedule(id).beneficiary;
        vm.prank(beneficiary);
        uint256 amount = vesting.claim(id);
        paid += amount;
        paidTo[beneficiary] += amount;
    }
}

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
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = VestingHandler.create.selector;
        selectors[1] = VestingHandler.claim.selector;
        selectors[2] = VestingHandler.advanceTime.selector;
        selectors[3] = VestingHandler.donate.selector;
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
            uint256 vested;
            if (block.timestamp >= schedule.start + schedule.duration) {
                vested = schedule.amount;
            } else if (block.timestamp >= schedule.cliff) {
                vested = schedule.amount * (block.timestamp - schedule.start) / schedule.duration;
            }
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
