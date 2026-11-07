// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable 0.75% IMD fee for the SIMDTEST2 launch pool. This is a valueless test launch.
/// @dev No owner, setters, upgrade path, clocks, routers, allowances or user-supplied recipient.
contract TestHook is IUnlockCallback {
    using SafeCast for uint256;

    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant VAULT = 0xa9d495A0b10EE4A2a735c2E0f6D38C583194813A;
    uint256 public constant FEE_BPS = 75;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant FLAGS = 0x20cc;

    IPoolManager public immutable poolManager;
    address public immutable token;
    PoolId public immutable poolId;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidDeployment();
    error WrongPool();
    /// @dev Revert data carries a simulated delta; reverting rolls back every simulated state change.
    error SwapQuote(BalanceDelta delta);
    error UnexpectedQuoteReturn();

    event FeePaid(uint256 amount);
    event FeeDeferred(uint256 amount);
    event FeesFlushed(uint256 amount);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0) || token_ == IMD) {
            revert InvalidDeployment();
        }
        poolManager = manager_;
        token = token_;
        (address c0, address c1) = token_ < IMD ? (token_, IMD) : (IMD, token_);
        PoolKey memory key =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(address(this)));
        poolId = key.toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Accept only the immutable launch pool; any initializer may open it.
    /// @dev The factory deploys and initializes atomically. No price or sender restrictions are imposed.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Reserve the fee when IMD is the specified currency (exact-input buy / exact-output sell).
    /// @dev v4 cannot change the specified delta in afterSwap. A reverting self-call previews the
    /// actual fill at the user's price limit, so unfilled IMD is never taxed. No tokens move here.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!_imdIsSpecified(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        uint256 maxFee = _specifiedMaxFee(params.amountSpecified);
        if (maxFee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        SwapParams memory preview = params;
        // A positive exact-output request near int256.max is necessarily partial in v4's int128 deltas.
        uint256 headroom = params.amountSpecified > 0
            ? uint256(type(int256).max - params.amountSpecified)
            : type(uint256).max;
        preview.amountSpecified += int256(maxFee > headroom ? headroom : maxFee);
        BalanceDelta quoted = _quote(key, preview);
        uint256 fee = _specifiedFee(params.amountSpecified, _imdDelta(key, quoted));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @notice Pay the vault in IMD, or retain a redeemable IMD claim if direct payment fails.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        int128 imdDelta = _imdDelta(key, delta);
        bool specified = _imdIsSpecified(key, params);
        uint256 fee = specified
            ? _specifiedFee(params.amountSpecified, imdDelta)
            : _fraction(_abs(imdDelta), imdDelta < 0 ? BPS - FEE_BPS : BPS);
        if (fee != 0) _pay(fee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    /// @dev Internal simulation entry point. Only this hook can enter and it ALWAYS reverts.
    /// PoolManager skips this hook's callbacks when this hook is the swap caller. That prevents
    /// recursion and quotes only the real pool's math, LP fee, tick crossings and price limit.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert SwapQuote(delta);
    }

    /// @notice Anyone can redeem deferred IMD fees. The destination is always VAULT.
    /// @dev Run outside a manager unlock. Failed transfers revert this redemption and preserve claims.
    function flushFees() external returns (uint256 amount) {
        return abi.decode(poolManager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = pendingFees();
        // PoolManager operations use signed 128-bit deltas. Multiple redemptions handle larger totals.
        uint256 maximum = uint256(uint128(type(int128).max));
        if (amount > maximum) amount = maximum;
        if (amount != 0) {
            poolManager.burn(address(this), uint160(IMD), amount);
            poolManager.take(Currency.wrap(IMD), VAULT, amount);
            emit FeesFlushed(amount);
        }
        return abi.encode(amount);
    }

    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), uint160(IMD));
    }

    function _pay(uint256 fee) private {
        // If IMD is the manager's synced currency, a payer may still settle against the reserves
        // recorded at sync. Moving IMD out now would under-credit that settle, so keep a claim instead.
        if (Currency.unwrap(TransientStateLibrary.getSyncedCurrency(poolManager)) == IMD) {
            poolManager.mint(address(this), uint160(IMD), fee);
            emit FeeDeferred(fee);
            return;
        }
        try poolManager.take(Currency.wrap(IMD), VAULT, fee) {
            emit FeePaid(fee);
        } catch {
            // A failed take rolls back its debit. Minting debits the same fee without any token call.
            poolManager.mint(address(this), uint160(IMD), fee);
            emit FeeDeferred(fee);
        }
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (BalanceDelta delta) {
        try this.quoteSwap(key, params) {
            revert UnexpectedQuoteReturn();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != SwapQuote.selector) {
                // Preserve real pool errors (e.g. invalid price limits); do not fabricate a quote.
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            assembly ("memory-safe") {
                delta := mload(add(reason, 36))
            }
        }
    }

    function _specifiedMaxFee(int256 amount) private pure returns (uint256) {
        return _fraction(_abs(amount), amount < 0 ? BPS : BPS - FEE_BPS);
    }

    function _specifiedFee(int256 requested, int128 executed) private pure returns (uint256) {
        if (requested < 0) {
            uint256 maximum = _specifiedMaxFee(requested);
            uint256 spent = _abs(executed);
            if (spent == _abs(requested) - maximum) return maximum;
            return _fraction(spent, BPS - FEE_BPS);
        }
        return _fraction(_abs(executed), BPS);
    }

    function _fraction(uint256 amount, uint256 denominator) private pure returns (uint256) {
        // Equivalent to floor(amount * 75 / denominator), without overflowing for huge requests.
        return (amount / denominator) * FEE_BPS + ((amount % denominator) * FEE_BPS) / denominator;
    }

    function _abs(int256 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-(amount + 1)) + 1 : uint256(amount);
    }

    function _imdIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0 == params.zeroForOne) == (Currency.unwrap(key.currency0) == IMD);
    }

    function _imdDelta(PoolKey calldata key, BalanceDelta delta) private pure returns (int128) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }
}
