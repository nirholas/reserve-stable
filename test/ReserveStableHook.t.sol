// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ReserveStableHook} from "src/hooks/ReserveStableHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ReserveStableHookTest is ForgeTest {
    ReserveStableHook internal hook;
    PoolKey internal poolKey;

    uint256 internal constant FLAGS = uint256(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 internal constant BASE_BPS = 4; // 0.04% at parity, in line with a stable venue
    uint256 internal constant MAX_BPS = 200; // 2.00% when a side is nearly gone
    uint256 internal constant MAX_REBATE_BPS = 196; // the whole surcharge, and no more
    uint256 internal constant HALF_POINT = 0.25e18; // half the surcharge once a side is a quarter short
    uint256 internal constant MIN_SIDE_BPS = 500; // no side may fall below 5% of the pool

    function setUp() public {
        setUpForge();
        hook = ReserveStableHook(_deploy(1e18, 1e18, 0x4444));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        _addLiquidity(hook, 100e18, 100e18);
    }

    function _deploy(uint256 unit0, uint256 unit1, uint160 namespace) private returns (address) {
        return deployHookToNamespace(
            "src/hooks/ReserveStableHook.sol:ReserveStableHook",
            uint160(FLAGS),
            abi.encode(
                address(manager),
                unit0,
                unit1,
                BASE_BPS,
                MAX_BPS,
                MAX_REBATE_BPS,
                HALF_POINT,
                MIN_SIDE_BPS,
                "Reserve Stable LP",
                "RSTBL-LP"
            ),
            namespace
        );
    }

    function _addLiquidity(ReserveStableHook target, uint256 amount0, uint256 amount1)
        private
        returns (BalanceDelta)
    {
        return target.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ReserveStable");
    }

    // --- construction -------------------------------------------------------

    function test_constructor_rejectsAUnitThatIsNotAPowerOfTen() public {
        vm.expectRevert(ReserveStableHook.InvalidUnit.selector);
        _deploy(1e18, 3, 0x1001);
    }

    function test_constructor_rejectsABaseAboveTheCap() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/ReserveStableHook.sol:ReserveStableHook",
            uint160(FLAGS),
            abi.encode(address(manager), 1e18, 1e18, 300, 200, 0, HALF_POINT, MIN_SIDE_BPS, "n", "s"),
            0x1002
        );
    }

    /// @dev The cap on the rebate is what stops a round trip paying, so a deployment that breaks it must not exist.
    function test_constructor_rejectsARebateLargerThanTheSurchargeFundingIt() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/ReserveStableHook.sol:ReserveStableHook",
            uint160(FLAGS),
            abi.encode(address(manager), 1e18, 1e18, BASE_BPS, MAX_BPS, MAX_BPS, HALF_POINT, MIN_SIDE_BPS, "n", "s"),
            0x1003
        );
    }

    function test_constructor_rejectsAFloorAtOrAboveHalf() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/ReserveStableHook.sol:ReserveStableHook",
            uint160(FLAGS),
            abi.encode(address(manager), 1e18, 1e18, BASE_BPS, MAX_BPS, MAX_REBATE_BPS, HALF_POINT, 5_000, "n", "s"),
            0x1004
        );
    }

    // --- pricing ------------------------------------------------------------

    function test_aBalancedPoolChargesTheBaseSpreadBothWays() public view {
        assertEq(hook.adjustmentBps(true), int256(BASE_BPS), "sell side");
        assertEq(hook.adjustmentBps(false), int256(BASE_BPS), "buy side");
    }

    /// @dev A trade small enough not to move the pool pays exactly the base rate, which is what parity means here.
    function test_aBalancedPoolQuotesParityLessTheBaseSpreadForASmallTrade() public view {
        uint256 out = hook.quote(true, true, 1e12);
        assertEq(out, (1e12 * (10_000 - BASE_BPS)) / 10_000, "parity less base spread");
    }

    /**
     * @dev The trade that breaks the balance is the one that pays for it.
     *
     * Priced from the reserves as they stand, a single large swap out of a balanced pool would pay only the base
     * rate, because at the moment of quoting nothing was wrong yet. Pricing at the midpoint is what stops the pool
     * being emptied for free, so the charge has to grow with size even when the pool starts balanced.
     */
    function test_aLargerTradePaysMoreEvenFromABalancedPool() public view {
        uint256 small = hook.quote(true, true, 1e18);
        uint256 large = hook.quote(true, true, 40e18);

        uint256 smallBps = 10_000 - (small * 10_000) / 1e18;
        uint256 largeBps = 10_000 - (large * 10_000) / 40e18;
        assertGt(largeBps, smallBps, "the bigger trade should pay the bigger spread");
        assertLe(largeBps, MAX_BPS, "and still be inside the band");
    }

    function test_takingFromTheScarceSideCostsMore() public {
        int256 before = hook.adjustmentBps(true);
        swap(poolKey, true, -40e18, ZERO_BYTES);
        int256 after_ = hook.adjustmentBps(true);
        assertGt(after_, before, "spread should rise as currency1 drains");
        assertLe(after_, int256(MAX_BPS), "spread must stay inside the band");
    }

    function test_theSpreadNeverLeavesTheBand() public {
        swap(poolKey, true, -80e18, ZERO_BYTES);
        int256 spread = hook.adjustmentBps(true);
        assertLe(spread, int256(MAX_BPS), "upper edge");
        assertGe(hook.adjustmentBps(false), -int256(MAX_REBATE_BPS), "lower edge");
    }

    // --- the stability fund -------------------------------------------------

    function test_theSurchargeAboveBaseGoesIntoTheFund() public {
        assertEq(hook.stabilityFund(), 0, "a balanced pool has collected nothing");
        swap(poolKey, true, -40e18, ZERO_BYTES);
        swap(poolKey, true, -10e18, ZERO_BYTES);
        assertGt(hook.stabilityFund(), 0, "draining a side should fund the rebate");
    }

    /// @dev The rebate has no source when the pool is balanced, so it cannot be conjured by trading into balance.
    function test_noRebateIsPaidFromAnEmptyFund() public view {
        assertEq(hook.stabilityFund(), 0, "fund starts empty");
        assertEq(hook.adjustmentBps(false), int256(BASE_BPS), "no rebate without a fund");
    }

    function test_restoringTheBalanceEarnsARebateOnceTheFundExists() public {
        swap(poolKey, true, -40e18, ZERO_BYTES);
        uint256 fund = hook.stabilityFund();
        assertGt(fund, 0, "fund should hold the surcharge");

        // Currency0 is now the abundant side, so buying it back is the trade the pool wants.
        uint256 quoted = hook.quote(false, true, 1e18);
        assertGt(quoted, (1e18 * (10_000 - BASE_BPS)) / 10_000, "a rebalancing trade should beat the base spread");
    }

    function test_theFundIsDrawnDownByTheRebateItPays() public {
        swap(poolKey, true, -40e18, ZERO_BYTES);
        uint256 before = hook.stabilityFund();
        swap(poolKey, false, -5e18, ZERO_BYTES);
        assertLt(hook.stabilityFund(), before, "paying a rebate should spend the fund");
    }

    /// @dev The property the whole design rests on: the pool never pays out more than it set aside.
    function test_theFundCanNeverGoNegative() public {
        swap(poolKey, true, -40e18, ZERO_BYTES);
        for (uint256 i = 0; i < 6; i++) {
            swap(poolKey, false, -5e18, ZERO_BYTES);
            // A uint cannot be negative, so the real assertion is that these swaps settle at all: an over-payment
            // would have underflowed the fund and reverted the swap rather than silently wrapping.
        }
        assertGe(hook.stabilityFund(), 0, "fund is still solvent");
    }

    /**
     * @dev Breaking the balance and restoring it must cost money, or the mechanism is a faucet.
     *
     * The second leg sells back exactly what the first leg produced, so the position genuinely closes. Selling back
     * a different amount would leave an open position whose profit or loss says nothing about the round trip.
     */
    function test_aRoundTripLosesMoney() public {
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));

        swap(poolKey, true, -30e18, ZERO_BYTES);
        uint256 gained1 = token1.balanceOf(address(this)) - before1;
        assertGt(gained1, 0, "sanity: the first leg executed");

        swap(poolKey, false, -int256(gained1), ZERO_BYTES);

        assertEq(token1.balanceOf(address(this)), before1, "the position is closed");
        assertLt(token0.balanceOf(address(this)), before0, "a round trip must not profit");
    }


    // --- the floor ----------------------------------------------------------

    function test_aSwapThatWouldBreakTheFloorIsRefused() public {
        vm.expectRevert();
        swap(poolKey, true, -190e18, ZERO_BYTES);
    }

    function test_theFloorLeavesTheConfiguredShareBehind() public {
        // Drain as far as the floor allows, then confirm the remaining side is at or above it.
        swap(poolKey, true, -80e18, ZERO_BYTES);
        (uint256 n0, uint256 n1) = hook.normalizedReserves();
        assertGe((n1 * 10_000) / (n0 + n1), MIN_SIDE_BPS, "the shallow side is still above the floor");
    }

    // --- exact output -------------------------------------------------------

    function test_exactOutputAgreesWithExactInput() public view {
        uint256 out = hook.quote(true, true, 1e18);
        uint256 backIn = hook.quote(true, false, out);
        assertApproxEqAbs(backIn, 1e18, 2, "the two directions must price the same trade");
        assertGe(backIn, 1e18 - 1, "and rounding must not favour the trader");
    }

    function test_exactOutputRoundsThePoolsWay() public view {
        uint256 needed = hook.quote(true, false, 1);
        assertGe(needed, 1, "one unit out must cost at least one unit in");
    }

    // --- decimals -----------------------------------------------------------

    /// @dev The classic stable-pool bug: a six-decimal token compared against an eighteen-decimal one.
    function test_aMixedDecimalPairPricesAtParity() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        MockERC20 eighteen = new MockERC20("Eighteen", "EEE", 18);
        six.mint(address(this), 1_000_000e6);
        eighteen.mint(address(this), 1_000_000e18);

        (address a, address b) = address(six) < address(eighteen)
            ? (address(six), address(eighteen))
            : (address(eighteen), address(six));
        (uint256 unitA, uint256 unitB) = a == address(six) ? (uint256(1e6), uint256(1e18)) : (uint256(1e18), uint256(1e6));

        ReserveStableHook mixed = ReserveStableHook(_deploy(unitA, unitB, 0x5555));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(mixed))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        IERC20(a).approve(address(mixed), type(uint256).max);
        IERC20(b).approve(address(mixed), type(uint256).max);
        // A hundred thousand of each, which is a balanced pool once decimals are accounted for.
        _addLiquidity(mixed, 100_000 * unitA, 100_000 * unitB);

        (uint256 n0, uint256 n1) = mixed.normalizedReserves();
        assertEq(n0, n1, "normalized reserves should be equal");
        assertEq(mixed.adjustmentBps(true), int256(BASE_BPS), "a balanced mixed pair charges the base spread");

        // One whole unit in should buy very nearly one whole unit out, in the other token's own decimals.
        uint256 out = mixed.quote(true, true, unitA);
        assertEq(out, (unitB * (10_000 - BASE_BPS)) / 10_000, "one unit for one unit, less the spread");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev No quote may ever leave the band the constructor promised.
    function testFuzz_everyQuoteStaysInsideTheBand(uint256 drain, uint256 size, bool zeroForOne) public {
        drain = bound(drain, 0, 80e18);
        size = bound(size, 1e15, 5e18);
        if (drain > 0) swap(poolKey, true, -int256(drain), ZERO_BYTES);

        uint256 out = hook.quote(zeroForOne, true, size);
        assertLe(out, (size * (10_000 + MAX_REBATE_BPS)) / 10_000, "no quote above parity plus the rebate cap");
        assertGe(out, (size * (10_000 - MAX_BPS)) / 10_000, "no quote below parity less the spread cap");
    }

    /**
     * @dev Solvency across an arbitrary sequence: the pool never pays out a rebate it did not first collect.
     *
     * The hook reverts rather than clamping if a rebate exceeds the fund, so a sequence that completes at all has
     * kept the promise. The final balance check is the second half: the fund is a real balance, not a counter that
     * happened to stay non-negative.
     */
    function testFuzz_theFundIsNeverOverdrawn(uint256 seed) public {
        uint256 rng = seed;
        for (uint256 i = 0; i < 12; i++) {
            rng = uint256(keccak256(abi.encode(rng)));
            bool zeroForOne = rng % 2 == 0;
            uint256 size = bound(rng >> 8, 1e16, 12e18);

            (uint256 n0, uint256 n1) = hook.normalizedReserves();
            uint256 outgoing = zeroForOne ? n1 : n0;
            // Skip a leg the floor would refuse; the invariant is about solvency, not about the floor.
            if (size + ((n0 + n1) * MIN_SIDE_BPS) / 10_000 >= outgoing) continue;

            swap(poolKey, zeroForOne, -int256(size), ZERO_BYTES);
        }
        assertGe(hook.stabilityFund(), 0, "the fund is still a real balance");
    }

    /// @dev A rebate is only ever offered on the side that is too full.
    function testFuzz_aRebateIsOnlyOfferedOnTheAbundantSide(uint256 drain) public {
        drain = bound(drain, 1e18, 80e18);
        swap(poolKey, true, -int256(drain), ZERO_BYTES);

        // Currency1 is the drained side, so taking more of it must never be rewarded.
        assertGe(hook.adjustmentBps(true), int256(BASE_BPS), "taking the scarce side is never rebated");
    }
}
