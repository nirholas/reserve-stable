// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title ReserveStableHook
 * @notice A pegged-pair pool that pays arbitrageurs to rebalance it, out of a fund it filled while going wrong.
 *
 * @dev Every stable pool in production prices with a curve that is flat near parity and steep away from it, and every
 * one of them shares a defect: the only force restoring balance is the price the curve happens to quote. When one
 * side runs low, the pool makes it expensive to take more, and then it waits. Nothing pays anybody to bring the
 * missing side back. Arbitrage does it eventually, if an external venue happens to make it worth doing, and if it
 * does not, the pool sits lopsided with its deep side useless and its shallow side unusable.
 *
 * This pool prices at parity and adjusts with a signed spread rather than a curve.
 *
 * A trade that takes from the scarce side pays a spread that grows as that side gets scarcer, from `baseSpreadBps`
 * up to `maxSpreadBps`. That much is ordinary. The part that is not: everything charged above the base rate goes
 * into an explicit stability fund rather than to the providers, and a trade that takes from the *abundant* side is
 * paid a rebate out of that fund. Restoring the balance is not merely cheaper than breaking it, it is profitable, and
 * it is profitable in exact proportion to how badly the pool needs it.
 *
 * The fund is what makes this safe rather than a subsidy with no source. It only ever grows from spread charged above
 * the base rate, and no rebate can exceed it, so across any sequence of trades the pool pays out strictly less than
 * it took in for this purpose. Providers cannot be made worse off than they would have been in the same pool charging
 * a flat `baseSpreadBps` and nothing else, which is a property, not an aspiration: it follows from the fund being a
 * separate balance that a rebate can only draw down.
 *
 * The round trip does not pay either. `maxRebateBps` is capped at `maxSpreadBps - baseSpreadBps` at construction, so
 * breaking the balance and restoring it costs the base spread twice and recovers at most what breaking it paid in.
 * The fund is also empty when the pool is balanced, which is exactly when a round-tripper would want to start.
 *
 * Underneath both of those sits a floor: no swap may leave either side holding less than `minSideBps` of the pool.
 * That is the band. A pegged pool that will sell the last unit of one side at any price is a pool that can be emptied,
 * and no spread schedule fixes that, because the last unit is worth more than any finite fee.
 *
 * Reserves are normalized to eighteen decimals from the units given at construction, so a six-decimal stablecoin and
 * an eighteen-decimal one are compared correctly rather than off by a factor of a trillion.
 *
 * @custom:slug reserve-stable
 * @custom:family Curves
 * @custom:prior-art Curve's StableSwap and the v4 hooks that reimplement it quote a flat-then-steep curve. Frax's AMOs, Angle's transmuter and Reflexer's redemption rate move a peg by minting or by changing a target, all with a governed controller. Dynamic-fee hooks price imbalance in one direction only, because a fee cannot be negative. A v4 pool that pays a bounded negative spread to whoever restores its balance, funded solely by the surcharge it collected while losing that balance, and provably unable to pay out more than it took in, is the contribution here.
 * @custom:limitation Only sound for a genuinely pegged pair. The fund is denominated in normalized units and treats one side as interchangeable with the other, which is true while the peg holds and false the moment it does not: against an asset that has actually broken, this pool will pay a rebate for taking the good side and call it rebalancing. Pair it with a depeg guard rather than trusting it alone. The pricing is also constant-sum, so it never quotes anything but parity plus a spread, and it does not move the v4 pool price at all, which means it publishes no oracle a downstream contract can read.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ReserveStableHook is ForgeCurveHook {
    using FeeMath for uint256;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Fixed-point one, for the normalized reserve arithmetic.
    uint256 internal constant WAD = 1e18;

    /// @notice One whole unit of currency0, i.e. `10 ** decimals0`.
    uint256 public immutable unit0;

    /// @notice One whole unit of currency1.
    uint256 public immutable unit1;

    /// @notice The spread charged when the pool is perfectly balanced, in basis points.
    uint256 public immutable baseSpreadBps;

    /// @notice The spread charged as the outgoing side approaches empty. The upper edge of the band.
    uint256 public immutable maxSpreadBps;

    /// @notice The largest rebate a rebalancing trade may earn. Capped at `maxSpreadBps - baseSpreadBps`.
    uint256 public immutable maxRebateBps;

    /// @notice Imbalance, as a fraction of half the pool, at which the spread sits halfway to its cap.
    uint256 public immutable halfPointWad;

    /// @notice The share of the pool, in basis points, that neither side may be pushed below.
    uint256 public immutable minSideBps;

    /**
     * @notice Value collected above the base spread and not yet paid back out, in normalized units.
     * @dev The bound on every rebate this pool will ever pay. It is not providers' money and it is not anybody's to
     * withdraw: it exists to be handed to whoever brings the pool back to balance.
     */
    uint256 public stabilityFund;

    /// @dev The fee figure for the current swap, computed once in {_getUnspecifiedAmount} and read back for the event.
    uint256 private _pendingFee;

    /// @dev A unit must be a power of ten no larger than 1e18, because that is what a token's decimals can produce.
    error InvalidUnit();

    /// @dev The base spread must sit below the cap, and the cap below a tenth.
    error InvalidSpread();

    /// @dev A rebate larger than the surcharge that funds it would make the round trip profitable.
    error RebateTooLarge();

    /// @dev The floor must leave room to trade, so it has to be below half the pool.
    error InvalidFloor();

    /// @dev The half point of the spread curve cannot be zero, or the spread jumps to its cap immediately.
    error InvalidHalfPoint();

    /// @dev A quantity too large to be represented as a signed integer, which no real reserve reaches.
    error ValueTooLarge();

    /// @dev A rebate came out larger than the fund backing it, which the quote is supposed to make impossible.
    error FundInsolvent(uint256 paid, uint256 held);

    /// @dev The pool holds nothing yet, so there is no balance to price against.
    error NoReserves();

    /// @dev The swap would push a side below the floor, which is the one thing this pool will not do.
    error BreaksFloor(uint256 remaining, uint256 floor);

    /**
     * @notice Emitted for every swap, with the signed adjustment applied and the fund it moved.
     * @param zeroForOne Direction of the swap.
     * @param adjustmentBps Positive when the trader paid a spread, negative when they were paid a rebate.
     * @param fundAfter The stability fund once the swap settled.
     */
    event Priced(bool zeroForOne, int256 adjustmentBps, uint256 fundAfter);

    constructor(
        IPoolManager _poolManager,
        uint256 _unit0,
        uint256 _unit1,
        uint256 _baseSpreadBps,
        uint256 _maxSpreadBps,
        uint256 _maxRebateBps,
        uint256 _halfPointWad,
        uint256 _minSideBps,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        if (!_isUnit(_unit0) || !_isUnit(_unit1)) revert InvalidUnit();
        if (_baseSpreadBps >= _maxSpreadBps || _maxSpreadBps > 1_000) revert InvalidSpread();
        if (_maxRebateBps > _maxSpreadBps - _baseSpreadBps) revert RebateTooLarge();
        if (_halfPointWad == 0) revert InvalidHalfPoint();
        if (_minSideBps == 0 || _minSideBps >= BPS / 2) revert InvalidFloor();

        unit0 = _unit0;
        unit1 = _unit1;
        baseSpreadBps = _baseSpreadBps;
        maxSpreadBps = _maxSpreadBps;
        maxRebateBps = _maxRebateBps;
        halfPointWad = _halfPointWad;
        minSideBps = _minSideBps;
    }

    /**
     * @dev A checked conversion to a signed integer.
     *
     * Every value converted here is bounded well below the limit by construction (basis points cannot exceed ten
     * thousand, a fund movement cannot exceed the reserves), but the bound lives in a different function from the
     * cast in each case, so it is enforced rather than asserted in a comment.
     */
    function _signed(uint256 value) private pure returns (int256) {
        if (value > uint256(type(int256).max)) revert ValueTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }

    /**
     * @dev A checked conversion back to an unsigned integer.
     *
     * The values passed here are `BPS` less the adjustment, which is positive for every configuration the constructor
     * accepts, since the spread is capped at a tenth. Checking it anyway means a future change to that cap cannot turn
     * a quote into a wildly wrong number instead of a revert.
     */
    function _unsigned(int256 value) private pure returns (uint256) {
        if (value <= 0) revert ValueTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value);
    }

    /// @dev Whether `unit` is a power of ten between 1 and 1e18, which is the whole range a token's decimals allow.
    function _isUnit(uint256 unit) private pure returns (bool) {
        for (uint256 candidate = 1; candidate <= 1e18; candidate *= 10) {
            if (candidate == unit) return true;
        }
        return false;
    }

    /// @notice The pool's reserves scaled to a common eighteen decimals, which is the space every quote is priced in.
    function normalizedReserves() public view returns (uint256 n0, uint256 n1) {
        (uint256 r0, uint256 r1) = reserves();
        n0 = (r0 * WAD) / unit0;
        n1 = (r1 * WAD) / unit1;
    }

    /**
     * @notice The signed adjustment this pool would apply to a swap right now, in basis points.
     * @dev Positive is a spread the trader pays; negative is a rebate the trader receives. This is the marginal rate,
     * meaning the price of a trade small enough not to move the pool. A real trade is priced at its own midpoint and
     * so pays more (or is rebated less) than this, in proportion to how far it moves the balance.
     * @param zeroForOne Whether the trade sells currency0.
     */
    function adjustmentBps(bool zeroForOne) public view returns (int256) {
        (uint256 n0, uint256 n1) = normalizedReserves();
        (int256 adjustment,) = _adjustment(zeroForOne, n0, n1, 0);
        return adjustment;
    }

    /**
     * @dev The signed adjustment, and the fund movement it implies.
     *
     * The imbalance is measured at the midpoint of the trade rather than where it started. That is not a refinement,
     * it is what makes the mechanism work: priced from the starting reserves, the single large trade that takes a
     * balanced pool and empties half of one side pays nothing above the base rate, because when it was quoted the
     * pool was still balanced. The fund would then be empty at exactly the moment a rebate is worth paying, and the
     * damage would have been done for free. Measured at the midpoint, a trade pays in proportion to how far it moves
     * the pool, which is the thing actually being charged for.
     *
     * `tradeWad` is the trade's size at parity. Passing zero gives the marginal rate, which is what a quote for an
     * infinitesimal trade means and what {adjustmentBps} publishes.
     *
     * @return adjustment Positive for a spread, negative for a rebate, both in basis points.
     * @return fundDelta Signed movement of the stability fund, in normalized units.
     */
    function _adjustment(bool zeroForOne, uint256 n0, uint256 n1, uint256 tradeWad)
        private
        view
        returns (int256 adjustment, int256 fundDelta)
    {
        uint256 total = n0 + n1;
        if (total == 0) revert NoReserves();

        // The side the trader is taking out. That is what scarcity is measured on: a pool short of what you want is
        // the case worth pricing, and a pool short of what you are bringing is a pool you are already helping.
        uint256 outgoing = zeroForOne ? n1 : n0;
        uint256 step = tradeWad / 2;
        uint256 midpoint = outgoing > step ? outgoing - step : 0;

        // Trading at parity moves the same quantity in as out, so the total is unchanged and half of it is the
        // balance point both before and after.
        uint256 half = total / 2;

        if (midpoint < half) {
            // Scarce. Charge above the base rate, and set the excess aside.
            uint256 shortfallWad = ((half - midpoint) * WAD) / half;
            uint256 extra = FeeMath.saturating(maxSpreadBps - baseSpreadBps, shortfallWad, halfPointWad);
            adjustment = _signed(baseSpreadBps + extra);
            fundDelta = _signed((tradeWad * extra) / BPS);
        } else {
            // Abundant. Pay for the rebalance, but never more than the fund holds.
            uint256 surplusWad = ((midpoint - half) * WAD) / half;
            uint256 rebate = FeeMath.saturating(maxRebateBps, surplusWad, halfPointWad);

            uint256 affordable = tradeWad == 0 ? rebate : (stabilityFund * BPS) / tradeWad;
            if (rebate > affordable) rebate = affordable;

            adjustment = _signed(baseSpreadBps) - _signed(rebate);
            fundDelta = -_signed((tradeWad * rebate) / BPS);
        }
    }

    /// @dev Applies a signed basis-point adjustment to a normalized amount, always rounding the pool's way.
    function _applyAdjustment(uint256 amountWad, int256 adjustment, bool exactInput) private pure returns (uint256) {
        // The trader's loss is a positive adjustment, so an exact-input quote shrinks and an exact-output quote grows.
        uint256 numerator = exactInput ? _unsigned(_signed(BPS) - adjustment) : BPS;
        uint256 denominator = exactInput ? BPS : _unsigned(_signed(BPS) - adjustment);
        if (exactInput) return (amountWad * numerator) / denominator;
        // Round the trader's payment up by a wei, so rounding can never come out of the reserves.
        return (amountWad * numerator + denominator - 1) / denominator;
    }

    /// @dev Everything one quote produces. A struct rather than four return values, which will not fit on the stack.
    struct Quote {
        /// @notice The unspecified amount, in its own units.
        uint256 result;
        /// @notice Positive for a spread the trader paid, negative for a rebate they received.
        int256 adjustment;
        /// @notice Signed movement of the stability fund, in normalized units.
        int256 fundDelta;
        /// @notice The spread charged, in the unspecified currency's units, for the base contract's event.
        uint256 fee;
    }

    /**
     * @notice What this pool would give for a trade, with the spread or rebate already applied.
     * @param zeroForOne Whether the trade sells currency0.
     * @param exactInput Whether `specified` is the amount paid in rather than the amount taken out.
     * @param specified The amount, in the specified currency's own units.
     * @return The unspecified amount, in its own units.
     */
    function quote(bool zeroForOne, bool exactInput, uint256 specified) public view returns (uint256) {
        return _quote(zeroForOne, exactInput, specified).result;
    }

    /// @dev One whole unit of the currency the trader pays, and of the one they receive.
    function _units(bool zeroForOne) private view returns (uint256 inUnit, uint256 outUnit) {
        return zeroForOne ? (unit0, unit1) : (unit1, unit0);
    }

    /**
     * @dev The whole quote.
     *
     * Both directions are priced from the same signed adjustment, so an exact-output quote is the exact-input quote
     * solved the other way rather than a second schedule that could disagree with the first.
     */
    function _quote(bool zeroForOne, bool exactInput, uint256 specified) private view returns (Quote memory q) {
        (uint256 n0, uint256 n1) = normalizedReserves();
        (uint256 inUnit, uint256 outUnit) = _units(zeroForOne);

        // The trade's size at parity. The true payment is not known until the adjustment is, and the adjustment
        // depends on the size, so the parity-equivalent figure is used for both the midpoint and the fund cap. It is
        // within a spread's width of the truth, which for a pegged pair is a rounding error on a rounding error.
        uint256 specifiedWad = (specified * WAD) / (exactInput ? inUnit : outUnit);
        (q.adjustment, q.fundDelta) = _adjustment(zeroForOne, n0, n1, specifiedWad);

        uint256 resultWad = _applyAdjustment(specifiedWad, q.adjustment, exactInput);
        uint256 inWad = exactInput ? specifiedWad : resultWad;
        uint256 outWad = exactInput ? resultWad : specifiedWad;
        _requireFloor(zeroForOne, n0, n1, inWad, outWad);

        // Denominate back into the unspecified currency, rounding the pool's way in both directions.
        q.result = exactInput ? (resultWad * outUnit) / WAD : (resultWad * inUnit + WAD - 1) / WAD;

        uint256 spreadBps = q.adjustment > 0 ? uint256(q.adjustment) : 0;
        q.fee = (inWad * spreadBps * (exactInput ? outUnit : inUnit)) / (BPS * WAD);
    }

    /**
     * @dev Refuses a swap that would push either side below the floor.
     *
     * Checked on the reserves the swap would leave behind rather than the ones it started from, because a pool that
     * is above its floor before a trade and below it afterwards is exactly the trade this is here to stop.
     */
    function _requireFloor(bool zeroForOne, uint256 n0, uint256 n1, uint256 inWad, uint256 outWad) private view {
        uint256 outgoing = zeroForOne ? n1 : n0;
        uint256 totalAfter = n0 + n1 + inWad - (outWad > outgoing ? outgoing : outWad);
        uint256 floor = (totalAfter * minSideBps) / BPS;
        if (outWad > outgoing) revert BreaksFloor(0, floor);
        uint256 remaining = outgoing - outWad;
        if (remaining < floor) revert BreaksFloor(remaining, floor);
    }

    /**
     * @dev Prices the swap and moves the stability fund by what it charged or paid.
     *
     * The fund has to move here rather than in a later callback, because this is the only place that knows both the
     * adjustment and the size it was applied to. Moving it anywhere else would mean recovering both from a number
     * that has already had them folded into it.
     */
    function _getUnspecifiedAmount(SwapParams calldata params) internal override returns (uint256) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        Quote memory q = _quote(params.zeroForOne, exactInput, specified);

        if (q.fundDelta > 0) {
            stabilityFund += uint256(q.fundDelta);
        } else if (q.fundDelta < 0) {
            uint256 paid = _unsigned(-q.fundDelta);
            // The rebate was capped against this same balance when it was quoted, and the quote and the debit use the
            // identical figure, so this can only fail if that reasoning is wrong. Checked rather than clamped: a pool
            // that silently paid out more than it held would be exactly the failure this design claims to rule out.
            if (paid > stabilityFund) revert FundInsolvent(paid, stabilityFund);
            stabilityFund -= paid;
        }

        _pendingFee = q.fee;
        emit Priced(params.zeroForOne, q.adjustment, stabilityFund);
        return q.result;
    }

    /// @dev Reports the spread {_getUnspecifiedAmount} already applied. A rebated swap charged nothing, so reports zero.
    function _getSwapFeeAmount(SwapParams calldata, uint256) internal view override returns (uint256) {
        return _pendingFee;
    }

    function hookName() external pure override returns (string memory) {
        return "ReserveStable";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "reserve-stable.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "stablecoin";
        tags[2] = "custom-curve";
        tags[3] = "rebalancing";
        tags[4] = "no-admin";
    }
}
