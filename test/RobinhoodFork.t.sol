// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {SyncFirstRouter} from "./TestHook.t.sol";
import {TestHook} from "../src/TestHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Fork tests against Robinhood Chain (4663) live state at the pinned block.
/// @dev Reads the RPC from ROBINHOOD_RPC_URL (a URL or a socket path, passed as is) and skips only when
/// it is empty. The real IMD token, the real SIMD Test Vault and the real Uniswap v4 PoolManager are
/// used; a fresh launch token, hook and pool are deployed on top of that state, exactly as the factory
/// would, and only test actors are funded.
abstract contract RobinhoodForkBehavior is HookFixture {
    using StateLibrary for IPoolManager;

    /// @dev Uniswap v4 PoolManager on Robinhood Chain (Uniswap/contracts deployments/4663.md).
    address internal constant CHAIN_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 internal constant FORK_BLOCK = 108_279_434;

    function _forkSetup(bool imdFirst) internal {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        _configure(IPoolManager(CHAIN_MANAGER), imdFirst, true, true);
    }

    // ------------------------------------------------------------------
    // Live state
    // ------------------------------------------------------------------

    function testFork_pinnedChainHasRealIMDVaultAndManager() public view {
        assertEq(block.chainid, 4663, "must run on Robinhood Chain");
        assertGt(CHAIN_MANAGER.code.length, 0, "PoolManager has code");
        assertGt(IMD.code.length, 0, "IMD has code");
        assertGt(VAULT.code.length, 0, "SIMD Test Vault has code");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertEq(hook.IMD(), IMD);
        assertEq(hook.VAULT(), VAULT);
        assertEq(address(hook.poolManager()), CHAIN_MANAGER);
        assertEq(hook.token(), address(token));
        assertEq(token.name(), "SIMD TEST 2 - DO NOT BUY");
        assertEq(token.symbol(), "SIMDTEST2");
        (uint160 price,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, Q96, "pool opened on the real manager");
        assertEq(lpFee, 12_500, "factory LP fee");
    }

    // ------------------------------------------------------------------
    // 0.75% lands in the vault, in IMD, on buys and sells
    // ------------------------------------------------------------------

    function testFork_everyBuyAndSellModePaysVaultInIMD() public {
        uint256 vaultEth = VAULT.balance;
        uint256 vaultToken = token.balanceOf(VAULT);
        uint256 managerEth = CHAIN_MANAGER.balance;
        uint256 total;
        for (uint256 mode; mode < 4; ++mode) {
            // _trade asserts: fee == floor(gross executed IMD * 75 / 10000), fee paid in IMD to VAULT,
            // trader balances match the deltas, nothing held by the hook, and the manager fully settled.
            Trade memory t = _trade(mode < 2, mode % 2 == 0, 100 ether, 0, "");
            assertGt(t.paid, 0, "vault received IMD");
            assertEq(t.deferred, 0, "real manager holds IMD: paid directly");
            total += t.paid;
        }
        assertEq(VAULT.balance, vaultEth, "fee is never converted to ETH");
        assertEq(CHAIN_MANAGER.balance, managerEth, "no ETH moved by the hook");
        assertEq(token.balanceOf(VAULT), vaultToken, "fee is never taken in SIMDTEST2");
        assertEq(hook.pendingFees(), 0);
        assertGt(total, 0);
    }

    function testFork_exactInputBuyAndSellChargeExactly75Bps() public {
        // Exact-input buy: the IMD budget is the gross amount, so the fee is exactly 0.75% of it.
        Trade memory buy = _trade(true, true, 100 ether, 0, "");
        assertEq(buy.paid, 0.75 ether);
        int128 traderImd = imdIs0 ? buy.delta.amount0() : buy.delta.amount1();
        assertEq(traderImd, -100 ether, "the trader spends exactly the budget, fee included");

        // Exact-output sell: the trader receives exactly the requested net IMD, the vault the 0.75%.
        Trade memory sell = _trade(false, false, 50 ether, 0, "");
        traderImd = imdIs0 ? sell.delta.amount0() : sell.delta.amount1();
        assertEq(traderImd, 50 ether, "requested net IMD is delivered");
        assertEq(sell.paid, uint256(uint128(sell.coreImd)) * 75 / 10_000);
        assertEq(sell.paid, uint256(50 ether) * 75 / 9925, "full fill: fee = floor(R * 75 / 9925)");
    }

    /// @dev Every run trades on the same forked state; storage already read is served from forge's cache.
    function testForkFuzz_rateIsAlways75BpsOfGrossIMD(
        uint96 seed,
        bool buy,
        bool exactInput,
        uint32 secondsForward,
        uint32 blocksForward
    ) public {
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + blocksForward);
        uint256 amount = bound(uint256(seed), 1, 100_000 ether);
        Trade memory t = _trade(buy, exactInput, amount, 0, "");
        assertEq(t.deferred, 0);
        // _trade already asserted fee == floor(gross * 75 / 10000) for the executed gross IMD.
        assertLe(
            t.fee, (exactInput && buy ? amount : uint256(uint128(t.coreImd < 0 ? -t.coreImd : t.coreImd)))
        );
    }

    // ------------------------------------------------------------------
    // The rate never changes
    // ------------------------------------------------------------------

    function testFork_rateIdenticalAcrossTimeBlocksRoutersAndHookData() public {
        uint256 first = _trade(true, true, 100 ether, 0, "").paid;
        assertEq(first, 0.75 ether);

        // A launch-block buy, a buy a year later and a buy ten million blocks later all pay the same.
        vm.roll(block.number + 1);
        assertEq(_trade(true, true, 100 ether, 0, "").paid, first, "no anti-sniper rule in the next block");
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 10_000_000);
        assertEq(_trade(true, true, 100 ether, 0, "").paid, first, "no time schedule");

        // A different router and adversarial hookData change nothing either.
        address attacker = makeAddr("fork attacker");
        PoolActor other = new PoolActor(manager);
        actor = other;
        token.transfer(address(other), 1_000_000 ether);
        deal(IMD, address(other), 1_000_000 ether);
        uint256 second =
            _trade(true, true, 100 ether, 0, abi.encode(attacker, uint256(0), uint256(10_000))).paid;
        assertEq(second, first, "router identity and hookData cannot change the fee");
        assertEq(imd.balanceOf(attacker), 0);
        assertEq(hook.FEE_BPS(), 75);
        assertEq(hook.BPS(), 10_000);
    }

    // ------------------------------------------------------------------
    // Nothing can redirect the fee
    // ------------------------------------------------------------------

    function testFork_noCallerCanRedirectOrRetuneTheFee() public {
        address attacker = makeAddr("fork attacker");
        string[10] memory signatures = [
            "setFee(uint256)",
            "setFeeBps(uint256)",
            "setVault(address)",
            "setRecipient(address)",
            "setPoolManager(address)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "withdraw(address,uint256)",
            "sweep(address,address)"
        ];
        address[4] memory callers = [VAULT, attacker, address(this), CHAIN_MANAGER];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory callData = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(hook).call(callData);
                assertFalse(ok, "hook exposes no admin surface");
            }
        }

        // Forged callbacks are refused, so nobody can make the hook take or mint toward another address.
        SwapParams memory params = _params(true, true, 100 ether, 0);
        vm.startPrank(attacker);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.afterSwap(attacker, key, params, BalanceDelta.wrap(0), abi.encode(attacker));
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeSwap(attacker, key, params, "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeInitialize(attacker, key, Q96);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(attacker));
        vm.expectRevert(TestHook.OnlySelf.selector);
        hook.quoteSwap(key, params);
        // Flushing with nothing pending is a no-op and never pays the caller.
        assertEq(hook.flushFees(), 0);
        vm.stopPrank();

        Trade memory t = _trade(true, true, 100 ether, 0, abi.encode(attacker));
        assertEq(t.paid, 0.75 ether, "fee still reaches the vault");
        assertEq(imd.balanceOf(attacker), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(attacker, uint160(IMD)), 0);
    }

    /// @dev On a fresh manager whose pool was seeded with the launch token only, the manager holds no
    /// IMD when afterSwap runs, so the real IMD transfer fails. The swap must still succeed, the fee is
    /// kept as an IMD claim, and anyone can later flush it to the vault (and only the vault).
    function testFork_tokenOnlyManagerDefersRealIMDThenFlushesToVault() public {
        _configure(IPoolManager(address(new PoolManager(address(this)))), imdIs0, true, false);
        actor.modify(
            key,
            ModifyLiquidityParams(imdIs0 ? int24(-120) : int24(60), imdIs0 ? int24(-60) : int24(120), 1e24, 0)
        );
        assertEq(imd.balanceOf(address(manager)), 0, "token-only seed");

        Trade memory t = _trade(true, true, 100 ether, 0, "");
        assertEq(t.paid, 0);
        assertEq(t.deferred, 0.75 ether);
        assertEq(hook.pendingFees(), 0.75 ether);

        address keeper = makeAddr("permissionless keeper");
        uint256 vaultBefore = imd.balanceOf(VAULT);
        vm.prank(keeper);
        assertEq(hook.flushFees(), 0.75 ether);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, 0.75 ether, "claim redeemed to the vault in IMD");
        assertEq(imd.balanceOf(keeper), 0, "keeper gets nothing");
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.flushFees(), 0, "second flush is a no-op");
    }

    /// @dev A router that calls sync(input) before swap and settles afterwards is legal v4 ordering. On a
    /// buy, IMD is the synced currency during afterSwap, so moving real IMD out would under-credit the
    /// router's settle; the hook must keep the fee as an IMD claim instead and the swap must succeed.
    /// On a sell the synced currency is SIMDTEST2, so the fee goes straight to the vault in IMD.
    function testFork_syncFirstRouterOnRealManagerStillPaysVaultInIMD() public {
        SyncFirstRouter router = new SyncFirstRouter(manager);
        deal(IMD, address(router), 1000 ether);
        token.transfer(address(router), 1000 ether);
        uint160 lo = TickMath.MIN_SQRT_PRICE + 1;
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        uint256 vaultBefore = imd.balanceOf(VAULT);
        uint256 managerImd = imd.balanceOf(address(manager));

        BalanceDelta d = router.swap(key, SwapParams(imdIs0, -100 ether, imdIs0 ? lo : hi));
        assertEq(imdIs0 ? d.amount0() : d.amount1(), -100 ether, "buyer spends exactly the budget");
        assertEq(imd.balanceOf(address(router)), 900 ether);
        assertEq(hook.pendingFees(), 0.75 ether, "fee kept as an IMD claim while IMD is synced");
        assertEq(imd.balanceOf(VAULT), vaultBefore, "no IMD moved out mid-settlement");
        assertEq(imd.balanceOf(address(manager)), managerImd + 100 ether, "manager holds the full budget");

        d = router.swap(key, SwapParams(!imdIs0, -100 ether, imdIs0 ? hi : lo));
        uint256 received = uint256(uint128(imdIs0 ? d.amount0() : d.amount1()));
        uint256 sellFee = imd.balanceOf(VAULT) - vaultBefore;
        assertGt(sellFee, 0);
        assertEq(sellFee, received * 75 / 9925, "sell fee paid directly, 0.75% of gross IMD");
        assertEq(imd.balanceOf(address(router)), 900 ether + received);
        assertEq(hook.pendingFees(), 0.75 ether, "sell did not touch the buy's claim");

        address keeper = makeAddr("fork keeper");
        vm.prank(keeper);
        assertEq(hook.flushFees(), 0.75 ether);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, sellFee + 0.75 ether, "claim redeemed to the vault only");
        assertEq(imd.balanceOf(keeper), 0);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    // ------------------------------------------------------------------
    // Failure paths against the real manager
    // ------------------------------------------------------------------

    function testFork_realManagerRejectsAnyOtherPoolOnThisHook() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong.fee = 0x800000; // dynamic-fee flag
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        // The launch pool cannot be opened twice.
        vm.expectRevert();
        manager.initialize(key, Q96);
    }

    function testFork_invalidOrUnfundedSwapsLeaveVaultUntouched() public {
        uint256 before = imd.balanceOf(VAULT);
        // Price limit equal to the current price is invalid in v4: the whole swap, fee included, reverts.
        vm.expectRevert();
        actor.swap(key, _params(true, true, 100 ether, Q96), "");
        // A router without IMD cannot settle; the fee paid in afterSwap is rolled back with it.
        PoolActor broke = new PoolActor(manager);
        vm.expectRevert();
        broke.swap(key, _params(true, true, 100 ether, 0), "");
        assertEq(imd.balanceOf(VAULT), before);
        assertEq(hook.pendingFees(), 0);
    }

    function testFork_partialFillsChargeOnlyExecutedIMD() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(-1) : int24(1));
        Trade memory buy = _trade(true, true, 100_000 ether, limit, "");
        assertGt(buy.paid, 0);
        assertLt(buy.paid, 750 ether, "unfilled budget is not taxed");
        limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(1) : int24(-1));
        Trade memory sell = _trade(false, false, 100_000 ether, limit, "");
        assertGt(sell.paid, 0);
        assertLt(sell.paid, 750 ether, "unfilled request is not taxed");
    }

    function testFork_liquidityFeesRemainCollectibleWithoutHookFee() public {
        _trade(true, true, 100 ether, 0, "");
        _trade(false, true, 100 ether, 0, "");
        uint256 before = imd.balanceOf(VAULT);
        BalanceDelta collected = _liquidity(0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertTrue(collected.amount0() > 0 || collected.amount1() > 0, "LP fees accrued");
        BalanceDelta removed = _liquidity(-int256(LIQUIDITY));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(imd.balanceOf(VAULT), before, "no hook fee on collect or removal");
    }
}

contract RobinhoodIMD0ForkTest is RobinhoodForkBehavior {
    function setUp() public {
        _forkSetup(true);
    }
}

contract RobinhoodIMD1ForkTest is RobinhoodForkBehavior {
    function setUp() public {
        _forkSetup(false);
    }
}
