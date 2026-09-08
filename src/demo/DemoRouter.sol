// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DemoRouter
 * @notice The smallest thing that lets a browser trade a Uniswap v4 pool: initialize it, provide liquidity, swap, and
 * withdraw, each in one transaction, with `hookData` passed through untouched.
 *
 * @dev Uniswap v4 is a singleton behind a lock. Nothing can touch a pool except from inside an `unlock` callback,
 * which means a front end cannot talk to it directly and needs a contract that opens the lock, does the work, and
 * settles what is owed. The production answer is the Universal Router, which is the right tool for real order flow
 * and the wrong one for a demo: driving it means building command bytes and Permit2 signatures before anybody can
 * click a button and watch a hook do its thing.
 *
 * This is the demo answer. Four entry points, ordinary ERC-20 approvals, no commands to encode, and `hookData`
 * forwarded exactly as given so a hook that needs a signature or an attestation can still be exercised from a web
 * page. It holds no funds between calls, has no owner and no upgrade path, and every token it moves comes from and
 * returns to the caller in the same transaction.
 *
 * It is deliberately not an aggregator and deliberately not gas-optimised. Use it to try a mechanism; use the
 * Universal Router to trade.
 *
 * Native ETH is not supported: every demo pool pairs two ERC-20s, and adding a payable settlement path would double
 * the surface of a contract whose whole value is being small enough to read in one sitting.
 */
contract DemoRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice The v4 singleton this router speaks to.
    IPoolManager public immutable poolManager;

    /// @dev What each entry point is asking the callback to do.
    enum Action {
        Swap,
        ModifyLiquidity
    }

    /// @dev Everything the callback needs, including who to settle with.
    struct Callback {
        Action action;
        address sender;
        PoolKey key;
        SwapParams swapParams;
        ModifyLiquidityParams liquidityParams;
        bytes hookData;
    }

    /// @dev Only the `PoolManager` may drive the callback.
    error NotPoolManager();

    /// @notice Emitted on every swap this router performs, so a front end can follow it without decoding v4's events.
    event DemoSwap(bytes32 indexed poolId, address indexed sender, int128 amount0, int128 amount1);

    /// @notice Emitted on every liquidity change this router performs.
    event DemoLiquidity(bytes32 indexed poolId, address indexed sender, int256 liquidityDelta);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /**
     * @notice Create the pool, if it does not exist.
     * @dev A plain forward. It exists so a front end has one contract to talk to rather than two, and because a hook
     * that rejects the pool at `afterInitialize` should fail here, where the demo can explain it, rather than in an
     * unrelated call the user did not make.
     */
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick) {
        return poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Swap, pulling what is owed from the caller and sending them what they are owed.
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        Callback memory callback = Callback({
            action: Action.Swap,
            sender: msg.sender,
            key: key,
            swapParams: params,
            liquidityParams: ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)}),
            hookData: hookData
        });
        delta = abi.decode(poolManager.unlock(abi.encode(callback)), (BalanceDelta));
        emit DemoSwap(PoolId.unwrap(key.toId()), msg.sender, delta.amount0(), delta.amount1());
    }

    /// @notice Add or remove liquidity. A positive `liquidityDelta` adds, a negative one removes.
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        Callback memory callback = Callback({
            action: Action.ModifyLiquidity,
            sender: msg.sender,
            key: key,
            swapParams: SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            liquidityParams: params,
            hookData: hookData
        });
        delta = abi.decode(poolManager.unlock(abi.encode(callback)), (BalanceDelta));
        emit DemoLiquidity(PoolId.unwrap(key.toId()), msg.sender, params.liquidityDelta);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        Callback memory callback = abi.decode(raw, (Callback));
        BalanceDelta delta;

        if (callback.action == Action.Swap) {
            delta = poolManager.swap(callback.key, callback.swapParams, callback.hookData);
        } else {
            // `feesAccrued` is folded into the caller's settlement rather than reported separately: for a demo, "what
            // changed in my balance" is the only number that matters.
            (BalanceDelta principal, BalanceDelta fees) =
                poolManager.modifyLiquidity(callback.key, callback.liquidityParams, callback.hookData);
            delta = principal + fees;
        }

        _settle(callback.key.currency0, callback.sender, delta.amount0());
        _settle(callback.key.currency1, callback.sender, delta.amount1());

        return abi.encode(delta);
    }

    /**
     * @dev Squares one currency with the pool.
     *
     * A negative delta is what the caller owes: pull it from them and pay the manager. A positive one is what they are
     * owed: take it out and send it. Zero needs nothing, and skipping it keeps a swap in one direction from touching
     * the other token at all.
     */
    function _settle(Currency currency, address sender, int128 amount) private {
        if (amount == 0) return;

        if (amount < 0) {
            // Casting to 'uint128' is safe because the branch establishes `amount < 0`, so `-amount` is a
            // positive int128 and fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-amount));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(poolManager), owed);
            poolManager.settle();
        } else {
            // Safe for the mirrored reason: this branch establishes `amount > 0`.
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(currency, sender, uint256(uint128(amount)));
        }
    }
}
