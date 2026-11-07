// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {TestHook} from "../src/TestHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @dev Legal v4 ordering: sync the input currency BEFORE the swap, then transfer and settle.
contract SyncFirstRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        manager.sync(input);
        BalanceDelta delta = manager.swap(key, params, "");
        int128 paid = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = params.zeroForOne ? delta.amount1() : delta.amount0();
        input.transfer(address(manager), uint256(-int256(paid)));
        manager.settle();
        if (received > 0) manager.take(output, address(this), uint128(received));
        return abi.encode(delta);
    }
}

abstract contract HookBehavior is HookFixture {
    using StateLibrary for IPoolManager;

    function test_exactInputBuyPaysIMD() public {
        Trade memory t = _trade(true, true, 100 ether, 0, "");
        assertEq(t.paid, 0.75 ether);
        assertEq(t.deferred, 0);
        assertEq(t.coreImd, -99.25 ether);
    }

    function test_exactInputSellPaysIMD() public {
        Trade memory t = _trade(false, true, 100 ether, 0, "");
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
        assertEq(imdIs0 ? t.delta.amount1() : t.delta.amount0(), -100 ether);
    }

    function test_exactOutputBuyPaysIMD() public {
        Trade memory t = _trade(true, false, 100 ether, 0, "");
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
        assertEq(imdIs0 ? t.delta.amount1() : t.delta.amount0(), 100 ether);
    }

    function test_exactOutputSellPreservesRequestedNetIMD() public {
        Trade memory t = _trade(false, false, 100 ether, 0, "");
        assertEq(t.paid, uint256(100 ether) * 75 / 9925);
        assertEq(t.deferred, 0);
        assertEq(imdIs0 ? t.delta.amount0() : t.delta.amount1(), 100 ether);
    }

    function testFuzz_allSwapModesConserveFunds(uint96 seed, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(seed), 1, 100_000 ether);
        Trade memory t = _trade(buy, exactInput, amount, 0, "");
        assertEq(t.deferred, 0);
        int128 specified = exactInput == (buy == imdIs0) ? t.delta.amount0() : t.delta.amount1();
        assertEq(int256(specified), exactInput ? -int256(amount) : int256(amount));
    }

    function testFuzz_partialFillsTaxOnlyExecutedIMD(uint96 seed, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(seed), 10_000 ether, 100_000 ether);
        bool zeroForOne = buy == imdIs0;
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        Trade memory t = _trade(buy, exactInput, amount, limit, "");
        int128 specified = exactInput == zeroForOne ? t.delta.amount0() : t.delta.amount1();
        assertGt(specified < 0 ? uint256(-int256(specified)) : uint128(specified), 0);
        assertLt(specified < 0 ? uint256(-int256(specified)) : uint128(specified), amount);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
    }

    function test_rateDoesNotChangeWithTimeBlocksOrHookData() public {
        Trade memory early = _trade(true, true, 100 ether, 0, "");
        vm.warp(50 * 365 days);
        vm.roll(200_000_000);
        Trade memory late =
            _trade(true, true, 100 ether, 0, abi.encode(address(this), uint256(0), "redirect"));
        assertEq(early.fee, late.fee);
        assertEq(hook.FEE_BPS(), 75);
        assertEq(hook.VAULT(), VAULT);
    }

    function test_dustRoundingDoesNotRevertOrOvercharge() public {
        _trade(true, true, 1, 0, "");
        _trade(true, true, 133, 0, "");
        Trade memory t = _trade(true, true, 134, 0, "");
        assertEq(t.fee, 1);
        _trade(false, false, 1, 0, "");
        _trade(false, false, 132, 0, "");
        _trade(false, false, 133, 0, "");
    }

    function test_zeroFillPaysNoFee() public {
        _local(imdIs0, false);
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            (uint160 price,,,) = manager.getSlot0(key.toId());
            uint160 limit = buy == imdIs0 ? price - 1 : price + 1;
            Trade memory t = _trade(buy, exactInput, 100 ether, limit, "");
            assertEq(BalanceDelta.unwrap(t.delta), 0);
            assertEq(t.fee, 0);
        }
    }

    function test_tokenOnlyManagerDefersFeeThenAnyoneCanFlush() public {
        _local(imdIs0, false);
        actor.modify(
            key,
            ModifyLiquidityParams(imdIs0 ? int24(-120) : int24(60), imdIs0 ? int24(-60) : int24(120), 1e24, 0)
        );
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        Trade memory t = _trade(true, true, 100 ether, 0, "");
        assertEq(t.paid, 0);
        assertEq(t.deferred, 0.75 ether);
        uint256 vaultBefore = imd.balanceOf(VAULT);
        vm.prank(makeAddr("permissionless keeper"));
        assertEq(hook.flushFees(), t.fee);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, t.fee);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.flushFees(), 0);
    }

    function test_syncFirstRouterBuysAndSellsWithFeeAccounted() public {
        SyncFirstRouter router = new SyncFirstRouter(manager);
        MockERC20(IMD).mint(address(router), 1000 ether);
        token.transfer(address(router), 1000 ether);
        uint256 before = imd.balanceOf(VAULT) + hook.pendingFees();

        // Buy: IMD is synced when afterSwap runs, so the fee is kept as a claim, not taken out.
        uint160 lo = TickMath.MIN_SQRT_PRICE + 1;
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = router.swap(key, SwapParams(imdIs0, -100 ether, imdIs0 ? lo : hi));
        assertEq(imdIs0 ? d.amount0() : d.amount1(), -100 ether);
        assertEq(imd.balanceOf(VAULT) + hook.pendingFees() - before, 0.75 ether);
        assertEq(hook.pendingFees(), 0.75 ether);

        // Sell: the synced currency is the launch token, so the fee is paid straight to the vault.
        uint256 vaultBefore = imd.balanceOf(VAULT);
        d = router.swap(key, SwapParams(!imdIs0, -100 ether, imdIs0 ? hi : lo));
        int128 received = imdIs0 ? d.amount0() : d.amount1();
        uint256 sellFee = imd.balanceOf(VAULT) - vaultBefore;
        assertEq(sellFee, uint256(uint128(received)) * 75 / 9925);
        assertEq(hook.pendingFees(), 0.75 ether);

        assertEq(hook.flushFees(), 0.75 ether);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, sellFee + 0.75 ether);
    }

    function test_revertingVaultTransferDoesNotBlockAnySwapMode() public {
        _failedTransfer(false);
    }

    function test_falseReturningVaultTransferDoesNotBlockAnySwapMode() public {
        _failedTransfer(true);
    }

    function _failedTransfer(bool returnFalse) private {
        MockERC20(IMD).blockRecipient(VAULT, returnFalse);
        uint256 expected;
        for (uint256 i; i < 4; ++i) {
            Trade memory t = _trade(i < 2, i % 2 == 0, 100 ether, 0, "");
            assertEq(t.paid, 0);
            assertGt(t.deferred, 0);
            expected += t.fee;
        }
        assertEq(hook.pendingFees(), expected);
        vm.expectRevert();
        hook.flushFees();
        assertEq(hook.pendingFees(), expected, "failed redemption must preserve claims");
        MockERC20(IMD).blockRecipient(address(0), false);
        uint256 before = imd.balanceOf(VAULT);
        vm.prank(makeAddr("stranger"));
        assertEq(hook.flushFees(), expected);
        assertEq(imd.balanceOf(VAULT) - before, expected);
    }

    function test_factoryCanCollectLPFeesAndRemoveLiquidity() public {
        _trade(true, true, 100 ether, 0, "");
        _trade(false, true, 100 ether, 0, "");
        uint256 before = imd.balanceOf(VAULT);
        BalanceDelta collected = _liquidity(0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertTrue(collected.amount0() > 0 || collected.amount1() > 0);
        BalanceDelta removed = _liquidity(-int256(LIQUIDITY));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(imd.balanceOf(VAULT), before, "no liquidity fee");
    }

    function test_permissionsAndConstructorImmutables() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
    }

    function test_everyEntryRefusesForgedManagerAndSelfCalls() public {
        SwapParams memory params = _params(true, true, 100 ether, 0);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(TestHook.OnlySelf.selector);
        hook.quoteSwap(key, params);
    }

    function test_initializationAndWrongPoolRejection() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), key, Q96), IHooks.beforeInitialize.selector);
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong.fee = 0;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = key;
        wrong.currency1 = Currency.wrap(makeAddr("unrelated token"));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeInitialize(address(this), wrong, Q96);
        vm.expectRevert();
        manager.initialize(key, Q96);
    }

    function test_noAdminCanRedirectOrChangeTheFee() public {
        address attacker = makeAddr("attacker");
        string[11] memory signatures = [
            "setFee(uint256)",
            "setFeeBps(uint256)",
            "setVault(address)",
            "setRecipient(address)",
            "setPoolManager(address)",
            "transferOwnership(address)",
            "pause()",
            "initialize(address)",
            "upgradeTo(address)",
            "withdraw(address,uint256)",
            "setToken(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory callData = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(VAULT);
            (bool vaultOk,) = address(hook).call(callData);
            assertFalse(vaultOk);
            (bool deployerOk,) = address(hook).call(callData);
            assertFalse(deployerOk);
            vm.prank(attacker);
            (bool attackerOk,) = address(hook).call(callData);
            assertFalse(attackerOk);
        }
        Trade memory t = _trade(true, true, 100 ether, 0, abi.encode(attacker, uint256(0)));
        assertEq(t.paid, 0.75 ether);
        assertEq(imd.balanceOf(attacker), 0);
    }

    function test_invalidSwapRollsBackFees() public {
        uint256 before = imd.balanceOf(VAULT);
        vm.expectRevert();
        actor.swap(key, _params(true, true, 100 ether, Q96), "");
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        actor.swap(key, _params(true, true, 0, 0), "");
        assertEq(imd.balanceOf(VAULT), before);
        assertEq(hook.pendingFees(), 0);
    }

    function test_failedRouterSettlementRollsBackVaultPayment() public {
        deal(IMD, address(actor), 0);
        uint256 vaultBefore = imd.balanceOf(VAULT);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.expectRevert();
        actor.swap(key, _params(true, true, 100 ether, 0), "");
        assertEq(imd.balanceOf(VAULT), vaultBefore);
        assertEq(hook.pendingFees(), 0);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
    }

    function test_reentrantTokenCannotForgeCallbacksOrRedeemDuringSwap() public {
        MockERC20(IMD).configureReentry(address(hook), abi.encodeCall(TestHook.flushFees, ()));
        _trade(true, true, 100 ether, 0, "");
        assertTrue(MockERC20(IMD).reentryAttempted());
        assertFalse(MockERC20(IMD).reentrySucceeded());
        MockERC20(IMD)
            .configureReentry(
                address(hook),
                abi.encodeCall(
                    TestHook.afterSwap,
                    (address(this), key, _params(true, true, 100 ether, 0), BalanceDelta.wrap(0), bytes(""))
                )
            );
        _trade(false, true, 100 ether, 0, "");
        assertTrue(MockERC20(IMD).reentryAttempted());
        assertFalse(MockERC20(IMD).reentrySucceeded());
    }

    function test_noAddressCanStealDeferredClaims() public {
        MockERC20(IMD).blockRecipient(VAULT, true);
        Trade memory t = _trade(true, true, 100 ether, 0, "");
        address attacker = makeAddr("claim thief");
        vm.prank(attacker);
        vm.expectRevert();
        manager.transferFrom(address(hook), attacker, uint160(IMD), t.fee);
        vm.prank(VAULT);
        vm.expectRevert();
        manager.transferFrom(address(hook), VAULT, uint160(IMD), t.fee);
        assertEq(hook.pendingFees(), t.fee);
    }

    function testFuzz_crossingInitializedTicksPreservesFeeAccounting(uint96 seed, bool buy, bool exactInput)
        public
    {
        actor.modify(key, ModifyLiquidityParams(-120, 120, int256(LIQUIDITY / 2), bytes32("inner")));
        actor.modify(key, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY / 4), bytes32("outer")));
        uint256 amount = bound(uint256(seed), 20_000 ether, 100_000 ether);
        uint160 limit = TickMath.getSqrtPriceAtTick(buy == imdIs0 ? int24(-180) : int24(180));
        _trade(buy, exactInput, amount, limit, "");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertTrue(tick <= -120 || tick >= 120, "cross an initialized tick");
    }

    function test_extremeSpecifiedRequestsCanStillPartiallyFill() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(-1) : int24(1));
        SwapParams memory params = _params(true, true, 1, limit);
        params.amountSpecified = type(int256).min;
        BalanceDelta d = actor.swap(key, params, "");
        assertLt(imdIs0 ? d.amount0() : d.amount1(), 0);
        limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(1) : int24(-1));
        params = _params(false, false, 1, limit);
        // v4 adds the specified hook fee to an exact-output request; leave representable headroom.
        params.amountSpecified = type(int256).max - type(int128).max;
        d = actor.swap(key, params, "");
        assertGt(imdIs0 ? d.amount0() : d.amount1(), 0);
    }

    function testFuzz_previewLeavesPoolStateIdenticalToOneCoreSwap(bool buy, bool exactInput) public {
        PoolKey memory baseline = key;
        baseline.hooks = IHooks(address(0));
        manager.initialize(baseline, Q96);
        actor.modify(
            baseline,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(LIQUIDITY), 0
            )
        );
        Trade memory t = _trade(buy, exactInput, 100 ether, 0, "");
        SwapParams memory params = _params(buy, exactInput, 100 ether, 0);
        if (buy == exactInput) params.amountSpecified += int256(t.fee);
        BalanceDelta plain = actor.swap(baseline, params, "");
        assertEq(imdIs0 ? plain.amount0() : plain.amount1(), t.coreImd);
        assertEq(imdIs0 ? plain.amount1() : plain.amount0(), imdIs0 ? t.delta.amount1() : t.delta.amount0());
        (uint160 hookedPrice, int24 hookedTick,,) = manager.getSlot0(key.toId());
        (uint160 plainPrice, int24 plainTick,,) = manager.getSlot0(baseline.toId());
        assertEq(hookedPrice, plainPrice);
        assertEq(hookedTick, plainTick);
    }

    function test_constructorRejectsInvalidInputsAndWrongFlags() public {
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        new TestHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        new TestHook(manager, address(0));
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        new TestHook(manager, IMD);
        // This known salt is selected by its predicted bits, not by assuming a CREATE address.
        bytes32 hash =
            keccak256(abi.encodePacked(type(TestHook).creationCode, abi.encode(manager, address(token))));
        bytes32 salt = keccak256("wrong permissions");
        assertFalse(HookFlags.matches(_predicted(salt, hash), FLAGS));
        vm.expectRevert();
        new TestHook{salt: salt}(manager, address(token));
    }
}

contract HookIMD0Test is HookBehavior {
    function setUp() public {
        _local(true, true);
    }
}

contract HookIMD1Test is HookBehavior {
    function setUp() public {
        _local(false, true);
    }
}
