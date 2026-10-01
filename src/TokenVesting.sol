// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fully funded, irrevocable linear vesting for a single launch token.
/// @dev Intended for the immutable, exact-transfer LaunchToken. No administrative powers.
contract TokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Schedule {
        address beneficiary;
        uint256 amount;
        uint256 claimed;
        uint256 start;
        uint256 cliff;
        uint256 duration;
    }

    error InvalidToken();
    error InvalidBeneficiary();
    error ZeroAmount();
    error InvalidTiming();
    error InexactDeposit();
    error UnknownSchedule(uint256 scheduleId);
    error NotBeneficiary();
    error NothingToClaim();

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed creator,
        address indexed beneficiary,
        uint256 amount,
        uint256 start,
        uint256 cliff,
        uint256 duration
    );
    event Claimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);

    IERC20 public immutable token;
    uint256 public scheduleCount;
    /// @notice All deposited tokens still owed, including both vested and unvested amounts.
    uint256 public totalLocked;
    mapping(uint256 scheduleId => Schedule) private _schedules;

    /// @param token_ Address of the already deployed LaunchToken; use $token in the launch manifest.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @notice Deposit your tokens to create an immutable schedule. IDs start at 1.
    /// @param beneficiary Only this address can claim; it also receives every payout.
    /// @param amount Amount in the token's smallest units, funded entirely by msg.sender.
    /// @param start Absolute Unix timestamp when accrual begins; may be in the past.
    /// @param cliff Absolute Unix timestamp when claims unlock, between start and start + duration.
    /// @param duration Nonzero number of seconds from start until the full amount is vested.
    function createSchedule(address beneficiary, uint256 amount, uint256 start, uint256 cliff, uint256 duration)
        external
        nonReentrant
        returns (uint256 scheduleId)
    {
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary();
        if (amount == 0) revert ZeroAmount();
        if (duration == 0 || duration > type(uint256).max - start) revert InvalidTiming();
        if (cliff < start || cliff > start + duration) revert InvalidTiming();

        // The guard prevents nested deposits/claims during funding. Publish a schedule only
        // after its exact funding is received; donations never count as a user's deposit.
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) revert InexactDeposit();

        scheduleId = ++scheduleCount;
        _schedules[scheduleId] = Schedule(beneficiary, amount, 0, start, cliff, duration);
        totalLocked += amount;

        emit ScheduleCreated(scheduleId, msg.sender, beneficiary, amount, start, cliff, duration);
    }

    /// @notice Claim all currently vested, unclaimed tokens in one schedule.
    function claim(uint256 scheduleId) external nonReentrant returns (uint256 amount) {
        Schedule storage schedule = _getSchedule(scheduleId);
        if (msg.sender != schedule.beneficiary) revert NotBeneficiary();
        amount = _vestedAmount(schedule, block.timestamp) - schedule.claimed;
        if (amount == 0) revert NothingToClaim();

        schedule.claimed += amount;
        totalLocked -= amount;
        emit Claimed(scheduleId, schedule.beneficiary, amount);
        token.safeTransfer(schedule.beneficiary, amount);
    }

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        return _getSchedule(scheduleId);
    }

    /// @notice Cumulative vested amount at a timestamp, independent of previous claims.
    function vestedAmount(uint256 scheduleId, uint256 timestamp) external view returns (uint256) {
        return _vestedAmount(_getSchedule(scheduleId), timestamp);
    }

    function claimableAmount(uint256 scheduleId) external view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);
        return _vestedAmount(schedule, block.timestamp) - schedule.claimed;
    }

    function _getSchedule(uint256 scheduleId) private view returns (Schedule storage schedule) {
        if (scheduleId == 0 || scheduleId > scheduleCount) revert UnknownSchedule(scheduleId);
        return _schedules[scheduleId];
    }

    function _vestedAmount(Schedule storage schedule, uint256 timestamp) private view returns (uint256) {
        if (timestamp < schedule.cliff) return 0;
        if (timestamp >= schedule.start + schedule.duration) return schedule.amount;
        // cliff >= start and duration > 0. Full-precision division rounds down, and the
        // end branch releases all remaining dust regardless of earlier claim frequency.
        return Math.mulDiv(schedule.amount, timestamp - schedule.start, schedule.duration);
    }
}
