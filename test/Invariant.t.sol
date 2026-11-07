// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract FeeHandler is HookFixture {
    using TransientStateLibrary for IPoolManager;

    uint256 public totalFees;
    uint256 private initialVault;
    uint256 private initialImd;
    bool public blocked;

    constructor(bool imdFirst) {
        _local(imdFirst, true);
        initialVault = imd.balanceOf(VAULT);
        initialImd = initialVault + imd.balanceOf(address(manager)) + imd.balanceOf(address(actor));
    }

    function trade(uint96 seed, bool buy, bool exactInput) external {
        uint256 amount = bound(uint256(seed), 1, 1000 ether);
        Trade memory t = _trade(buy, exactInput, amount, 0, "");
        totalFees += t.fee;
    }

    function setDeliveryFailure(bool fail, bool falseInsteadOfRevert) external {
        blocked = fail;
        MockERC20(IMD).blockRecipient(fail ? VAULT : address(0), falseInsteadOfRevert);
    }

    function flush() external {
        if (blocked && hook.pendingFees() != 0) vm.expectRevert();
        hook.flushFees();
    }

    function advanceTime(uint32 secondsForward, uint32 blocksForward) external {
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + blocksForward);
    }

    function assertAccounting() external view {
        assertEq(imd.balanceOf(VAULT) + hook.pendingFees(), initialVault + totalFees);
        assertEq(
            imd.balanceOf(VAULT) + imd.balanceOf(address(manager)) + imd.balanceOf(address(actor)), initialImd
        );
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(actor)),
            1e27
        );
        assertEq(token.totalSupply(), 1e27);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertFalse(manager.isUnlocked());
        assertEq(hook.VAULT(), VAULT);
        assertEq(hook.FEE_BPS(), 75);
    }
}

abstract contract FeeInvariant is Test {
    FeeHandler internal handler;

    function _setup(bool imdFirst) internal {
        handler = new FeeHandler(imdFirst);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = FeeHandler.trade.selector;
        selectors[1] = FeeHandler.setDeliveryFailure.selector;
        selectors[2] = FeeHandler.flush.selector;
        selectors[3] = FeeHandler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_vaultClaimsAndPoolBalancesConserveAllFunds() public view {
        handler.assertAccounting();
    }
}

contract IMD0InvariantTest is FeeInvariant {
    function setUp() public {
        _setup(true);
    }
}

contract IMD1InvariantTest is FeeInvariant {
    function setUp() public {
        _setup(false);
    }
}
