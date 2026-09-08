// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseCustomCurve} from "uniswap-hooks/base/BaseCustomCurve.sol";

import {ForgeMetadata} from "./ForgeMetadata.sol";

/**
 * @title ForgeCurveHook
 * @notice Base for HookForge hooks that replace Uniswap v4's swap maths with their own.
 *
 * @dev A curve hook is a different animal from a fee hook. It intercepts the swap before the pool's own maths runs,
 * quotes the trade itself, and settles the result, which means it also has to hold the reserves and account for the
 * people who supplied them. OpenZeppelin's {BaseCustomCurve} does the settlement and the ERC-6909 bookkeeping; this
 * adds the two things every such hook in this catalogue needs on top: an ERC-20 share token for liquidity providers,
 * and on-chain {IHookMetadata}.
 *
 * Two consequences are worth stating plainly, because they surprise people who have only written fee hooks.
 *
 * A curve hook serves exactly one pool. `BaseCustomCurve` binds the hook to the first pool that initializes with it,
 * because the reserves it holds and the shares it issues belong to that pool and could not be shared with another
 * without tracking them per pool and settling per pool, which is a different contract. Deploy one per pool.
 *
 * And liquidity does not work the way it does in a concentrated-liquidity pool. Providers deposit both sides in the
 * ratio the reserves are already in, receive fungible shares, and burn them to withdraw pro rata. There are no ticks
 * and no ranges, because the curve is not the one ticks describe.
 *
 * Share accounting deliberately follows the constant-product pair convention rather than anything curve-specific:
 * the first deposit mints the geometric mean of what it supplied, later deposits mint in proportion to the reserves
 * they join, and withdrawals return a pro-rata slice of both. That is independent of the curve, so a curve author
 * cannot get it subtly wrong, and it is the convention every integrator already understands.
 */
abstract contract ForgeCurveHook is BaseCustomCurve, ForgeMetadata, ERC20 {
    /**
     * @dev Shares permanently burned on the first deposit.
     *
     * Without it, the first provider can be front-run: deposit one wei, receive one share, donate a large amount
     * directly to the reserves, and every later depositor rounds down to zero shares. Locking a minimum makes the
     * attack cost more than it can extract. This is the same defence, and the same reasoning, as the constant-product
     * pair it borrows from.
     */
    uint256 internal constant MINIMUM_SHARES = 1_000;

    /// @dev A deposit was too small to mint any shares, or a withdrawal too small to return anything.
    error AmountTooSmall();

    /// @dev The first deposit must exceed the permanently locked minimum.
    error InsufficientInitialLiquidity();

    constructor(IPoolManager _poolManager, string memory shareName, string memory shareSymbol)
        BaseHook(_poolManager)
        ERC20(shareName, shareSymbol)
    {}

    /// @notice The hook's reserve of `currency`, held as an ERC-6909 claim on the `PoolManager`.
    function reserve(Currency currency) public view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice The pool's current reserves, in the pool key's currency order.
    function reserves() public view returns (uint256 reserve0, uint256 reserve1) {
        return (reserve(poolKey().currency0), reserve(poolKey().currency1));
    }

    /// @dev Integer square root, for the geometric mean the first deposit mints. Babylonian method.
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @dev Shares to mint for a deposit, and the amounts actually taken.
     *
     * Later deposits are trimmed to the reserve ratio rather than reverting on a mismatch, so a provider who supplies
     * slightly the wrong proportion gets a smaller position instead of a failed transaction.
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        virtual
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        (uint256 reserve0, uint256 reserve1) = reserves();
        uint256 supply = totalSupply();

        if (supply == 0 || reserve0 == 0 || reserve1 == 0) {
            amount0 = params.amount0Desired;
            amount1 = params.amount1Desired;
            uint256 minted = _sqrt(amount0 * amount1);
            if (minted <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            // The locked minimum is minted to this contract, where nobody can burn it.
            _mint(address(this), MINIMUM_SHARES);
            return (amount0, amount1, minted - MINIMUM_SHARES);
        }

        // Take whichever side is the binding constraint, and trim the other to match the reserve ratio.
        uint256 shares0 = (params.amount0Desired * supply) / reserve0;
        uint256 shares1 = (params.amount1Desired * supply) / reserve1;
        shares = shares0 < shares1 ? shares0 : shares1;
        if (shares == 0) revert AmountTooSmall();

        amount0 = (shares * reserve0) / supply;
        amount1 = (shares * reserve1) / supply;
    }

    /// @dev Amounts returned for a withdrawal, pro rata across both reserves.
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        (uint256 reserve0, uint256 reserve1) = reserves();
        uint256 supply = totalSupply();

        shares = params.liquidity;
        amount0 = (shares * reserve0) / supply;
        amount1 = (shares * reserve1) / supply;
        if (amount0 == 0 && amount1 == 0) revert AmountTooSmall();
    }

    /**
     * @dev Issues the shares a deposit earned.
     *
     * Shares go to `msg.sender`, which is the account that called `addLiquidity` and the account the tokens were
     * pulled from. A router adding liquidity for someone else therefore receives the shares and is responsible for
     * passing them on, which is the same contract every fungible pool makes.
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        virtual
        override
    {
        _mint(msg.sender, shares);
    }

    /// @dev Burns the shares a withdrawal spent, from the account that asked for it and received the tokens.
    function _burn(RemoveLiquidityParams memory params, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        virtual
        override
    {
        _burn(msg.sender, shares);
    }
}
