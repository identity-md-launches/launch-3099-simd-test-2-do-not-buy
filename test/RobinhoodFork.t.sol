// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Explicitly opt in with forge's --fork-url and --fork-block-number arguments.
/// No RPC or environment lookup occurs during the ordinary, entirely offline test suite.
/// The test manager address is sourced from Uniswap/contracts/deployments/4663.md, then checked on chain.
abstract contract RobinhoodForkBehavior is HookFixture {
    address internal constant CHAIN_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 internal constant FORK_BLOCK = 108_268_099;

    function _forkSetup(bool imdFirst) internal {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "must use Robinhood mainnet");
        // Nitro's NUMBER opcode exposes the parent L1 number, not the RPC's L2 block number.
        // These are the header values at Robinhood L2 block FORK_BLOCK.
        assertEq(block.number, 26_361_756, "wrong pinned header (L1 number)");
        assertEq(block.timestamp, 0x6aeedff9, "wrong pinned header (timestamp)");
        assertGt(CHAIN_MANAGER.code.length, 0);
        assertGt(IMD.code.length, 0);
        assertGt(VAULT.code.length, 0);
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        _configure(IPoolManager(CHAIN_MANAGER), imdFirst, true, true);
    }

    function testFork_buysAndSellsExactInputAndOutputPayRealIMDToVault() public {
        for (uint256 mode; mode < 4; ++mode) {
            Trade memory t = _trade(mode < 2, mode % 2 == 0, 100 ether, 0, "");
            assertGt(t.paid, 0);
            assertEq(t.deferred, 0);
        }
    }

    function testFork_rateAndDestinationRemainFixed() public {
        uint256 first = _trade(true, true, 100 ether, 0, "").paid;
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 10_000_000);
        address attacker = makeAddr("fork attacker");
        vm.prank(VAULT);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("setVault(address)", attacker));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("setFeeBps(uint256)", 9999));
        assertFalse(ok);
        uint256 second = _trade(true, true, 100 ether, 0, abi.encode(attacker)).paid;
        assertEq(first, 0.75 ether);
        assertEq(second, first);
        assertEq(imd.balanceOf(attacker), 0);
    }

    function testFork_partialBuyAndSellChargeExecutedAmount() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(-1) : int24(1));
        Trade memory buy = _trade(true, true, 100_000 ether, limit, "");
        assertLt(buy.paid, 750 ether);
        assertGt(buy.paid, 0);
        limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(1) : int24(-1));
        Trade memory sell = _trade(false, false, 100_000 ether, limit, "");
        assertLt(sell.paid, 750 ether);
        assertGt(sell.paid, 0);
    }

    function testFork_liquidityFeesRemainCollectible() public {
        _trade(true, true, 100 ether, 0, "");
        _trade(false, true, 100 ether, 0, "");
        uint256 before = imd.balanceOf(VAULT);
        _liquidity(0);
        _liquidity(-int256(LIQUIDITY));
        assertEq(imd.balanceOf(VAULT), before);
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
