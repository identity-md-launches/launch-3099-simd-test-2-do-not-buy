// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only IMD stand-in. Production never deploys or configures this contract.
contract MockERC20 is ERC20 {
    address public blockedRecipient;
    bool public returnFalse;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_) {
        if (supply_ != 0) _mint(msg.sender, supply_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address recipient, bool falseInsteadOfRevert) external {
        blockedRecipient = recipient;
        returnFalse = falseInsteadOfRevert;
    }

    function configureReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
        if (to == blockedRecipient) {
            if (returnFalse) return false;
            revert("mock IMD: recipient blocked");
        }
        return super.transfer(to, value);
    }
}
