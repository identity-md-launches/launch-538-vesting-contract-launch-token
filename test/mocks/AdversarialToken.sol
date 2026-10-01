// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenVesting} from "../../src/TokenVesting.sol";

/// @dev Test-only token for transfer failures and hostile callbacks; never a deployment artifact.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Revert,
        NoReturn,
        Fee,
        NoMovement,
        Reenter
    }

    error TransferRejected();

    Mode public depositMode;
    Mode public payoutMode;
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackCount;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Adversarial mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setModes(Mode deposit, Mode payout) external {
        depositMode = deposit;
        payoutMode = payout;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function approveFromToken(address spender, uint256 amount) external {
        _approve(address(this), spender, amount);
    }

    function claimFromToken(TokenVesting vesting, uint256 id) external returns (uint256) {
        return vesting.claim(id);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        return _perform(depositMode, from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        return _perform(payoutMode, msg.sender, to, value);
    }

    function _perform(Mode mode, address from, address to, uint256 value) private returns (bool) {
        if (mode == Mode.Revert) revert TransferRejected();
        if (mode == Mode.NoMovement) return true;
        if (mode == Mode.Fee) {
            _transfer(from, to, value - 1);
            _burn(from, 1);
        } else {
            _transfer(from, to, value);
        }
        if (mode == Mode.Reenter) {
            callbackCount++;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return mode != Mode.ReturnFalse;
    }
}
