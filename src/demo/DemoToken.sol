// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DemoToken
 * @notice A faucet token for the live hook demos. Anyone may mint, once per cooldown, up to a fixed amount.
 *
 * @dev The demos are the point of this repository being public: a mechanism you can read about but not touch is a
 * blog post. Touching one means holding both sides of a pool, which means a token anybody can get without asking
 * anyone. So this mints on demand, to whoever asks, with a cooldown that keeps a script from draining the supply
 * cap in one block.
 *
 * It is deliberately worthless and deliberately unlimited in aggregate. There is no owner, no pause, and no supply
 * cap beyond the per-address rate limit, because a demo token that can run out is a demo that stops working the
 * week after it ships.
 */
contract DemoToken is ERC20 {
    /// @notice How much a single claim mints.
    uint256 public constant CLAIM_AMOUNT = 1_000_000e18;

    /// @notice How long an address must wait between claims.
    uint256 public constant COOLDOWN = 4 hours;

    /// @notice When each address last claimed.
    mapping(address => uint256) public lastClaimAt;

    /// @dev The address claimed recently and must wait.
    error CooldownActive(uint256 secondsRemaining);

    /// @notice Emitted on every successful claim.
    event Claimed(address indexed to, uint256 amount);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mint the claim amount to the caller.
    function claim() external {
        claimTo(msg.sender);
    }

    /**
     * @notice Mint the claim amount to `to`.
     * @dev The cooldown is keyed on the recipient rather than the caller, so paying someone else's gas to fund them
     * is fine but funding one address repeatedly through different callers is not.
     */
    function claimTo(address to) public {
        uint256 last = lastClaimAt[to];
        // Cooldowns here are hours long, so the seconds a proposer can shift cannot meaningfully move one.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < last + COOLDOWN) {
            // forge-lint: disable-next-line(block-timestamp)
            revert CooldownActive(last + COOLDOWN - block.timestamp);
        }

        lastClaimAt[to] = block.timestamp;
        _mint(to, CLAIM_AMOUNT);
        emit Claimed(to, CLAIM_AMOUNT);
    }

    /// @notice Seconds until `account` may claim again. Zero when it may claim now.
    function cooldownRemaining(address account) external view returns (uint256) {
        uint256 last = lastClaimAt[account];
        if (last == 0) return 0;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 ready = last + COOLDOWN;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= ready ? 0 : ready - block.timestamp;
    }
}
