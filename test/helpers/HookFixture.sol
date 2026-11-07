// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TestHook} from "../../src/TestHook.sol";
import {TestToken} from "../../src/TestToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolActor} from "./PoolActor.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant VAULT = 0xa9d495A0b10EE4A2a735c2E0f6D38C583194813A;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant FLAGS = 0x20cc;
    uint256 internal constant LIQUIDITY = 1e24;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    TestToken internal token;
    TestHook internal hook;
    PoolActor internal actor;
    IERC20 internal imd = IERC20(IMD);
    PoolKey internal key;
    bool internal imdIs0;

    struct Trade {
        BalanceDelta delta;
        int128 coreImd;
        uint256 fee;
        uint256 paid;
        uint256 deferred;
    }

    struct Balances {
        uint256 vault;
        uint256 pending;
        uint256 actorImd;
        uint256 actorToken;
        uint256 totalImd;
        uint256 totalToken;
    }

    function _local(bool imdFirst, bool seed) internal {
        MockERC20 template = new MockERC20("Identity.md test double", "IMD", 0);
        vm.etch(IMD, address(template).code);
        _configure(IPoolManager(address(new PoolManager(address(this)))), imdFirst, false, seed);
    }

    function _configure(IPoolManager manager_, bool imdFirst, bool realImd, bool seed) internal {
        manager = manager_;
        imdIs0 = imdFirst;
        token = _deployToken(imdFirst);
        hook = _deployHook(manager, address(token));
        actor = new PoolActor(manager);
        key = PoolKey(
            Currency.wrap(imdFirst ? IMD : address(token)),
            Currency.wrap(imdFirst ? address(token) : IMD),
            12_500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, Q96);
        token.transfer(address(actor), 200_000_000 ether);
        if (realImd) deal(IMD, address(actor), 200_000_000 ether);
        else MockERC20(IMD).mint(address(actor), 200_000_000 ether);
        if (seed) _liquidity(int256(LIQUIDITY));
    }

    function _deployToken(bool imdFirst) internal returns (TestToken deployed) {
        bytes32 hash = keccak256(type(TestToken).creationCode);
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = keccak256(abi.encode(address(manager), i));
            address predicted = _predicted(salt, hash);
            if ((IMD < predicted) == imdFirst && predicted.code.length == 0) {
                deployed = new TestToken{salt: salt}();
                return deployed;
            }
        }
        revert("token salt not found");
    }

    function _deployHook(IPoolManager manager_, address token_) internal returns (TestHook deployed) {
        bytes32 hash = keccak256(abi.encodePacked(type(TestHook).creationCode, abi.encode(manager_, token_)));
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            if (HookFlags.matches(_predicted(salt, hash), FLAGS)) {
                deployed = new TestHook{salt: salt}(manager_, token_);
                return deployed;
            }
        }
        revert("hook salt not found");
    }

    function _predicted(bytes32 salt, bytes32 hash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }

    function _liquidity(int256 amount) internal returns (BalanceDelta) {
        return actor.modify(
            key,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), amount, bytes32(0))
        );
    }

    function _params(bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        view
        returns (SwapParams memory)
    {
        bool zeroForOne = buy == imdIs0;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit);
    }

    function _trade(bool buy, bool exactInput, uint256 amount, uint160 limit, bytes memory hookData)
        internal
        returns (Trade memory t)
    {
        Balances memory b;
        b.vault = imd.balanceOf(VAULT);
        b.pending = hook.pendingFees();
        b.actorImd = imd.balanceOf(address(actor));
        b.actorToken = token.balanceOf(address(actor));
        b.totalImd = imd.balanceOf(address(manager)) + b.actorImd + b.vault;
        b.totalToken = token.balanceOf(address(manager)) + b.actorToken;
        vm.recordLogs();
        t.delta = actor.swap(key, _params(buy, exactInput, amount, limit), hookData);
        t.coreImd = _coreImd(vm.getRecordedLogs());
        t.paid = imd.balanceOf(VAULT) - b.vault;
        t.deferred = hook.pendingFees() - b.pending;
        t.fee = t.paid + t.deferred;
        _assertTrade(t, buy, b);
    }

    function _coreImd(Vm.Log[] memory logs) internal view returns (int128 coreImd) {
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            // Foundry recordLogs also records logs from reverted calls. Only the outer actor's
            // event represents the committed swap; the preview's sender is the hook itself.
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(actor))))
            ) {
                (int128 a0, int128 a1,,,, uint24 lpFee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                coreImd = imdIs0 ? a0 : a1;
                assertEq(lpFee, 12_500, "LP fee changed");
                ++swaps;
            }
        }
        assertEq(swaps, 1, "one outer swap");
    }

    function _assertTrade(Trade memory t, bool buy, Balances memory b) internal view {
        int128 traderImd = imdIs0 ? t.delta.amount0() : t.delta.amount1();
        int128 traderToken = imdIs0 ? t.delta.amount1() : t.delta.amount0();
        assertEq(int256(t.coreImd) - int256(traderImd), int256(t.fee), "fee delta conservation");
        assertEq(int256(imd.balanceOf(address(actor))) - int256(b.actorImd), int256(traderImd));
        assertEq(int256(token.balanceOf(address(actor))) - int256(b.actorToken), int256(traderToken));
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(actor)) + imd.balanceOf(VAULT), b.totalImd
        );
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(actor)), b.totalToken);
        uint256 gross = buy ? uint256(-int256(traderImd)) : uint256(uint128(t.coreImd));
        assertEq(t.fee, gross * 75 / 10_000, "fee is 0.75% of gross executed IMD");
        assertEq(imd.balanceOf(address(hook)), 0, "hook must not custody IMD");
        assertEq(token.balanceOf(address(hook)), 0, "hook must not tax launch token");
        assertEq(address(hook).balance, 0, "no ETH conversion");
        assertEq(manager.getNonzeroDeltaCount(), 0, "all obligations settled");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
    }
}
