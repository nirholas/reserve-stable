// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";
import {ReserveStableHook} from "src/hooks/ReserveStableHook.sol";

/**
 * @title DeployLocal
 * @notice Brings this curve up on a local chain with two faucet tokens and enough liquidity to quote against.
 *
 * @dev A custom-curve hook holds its own reserves and issues its own shares, so liquidity goes in through the hook
 * rather than through a router, and the hook binds to the first pool that initializes with it.
 *
 *   anvil &
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *
 * Writes web/local.json, which the site's build merges. Anvil's first key is public by design; never use it for real.
 */
contract DeployLocal is Script {
    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q96 = 1 << 96;

    PoolManager internal manager;
    DemoToken internal weth;
    DemoToken internal dai;
    DemoRouter internal router;
    ReserveStableHook internal hook;
    PoolKey internal key;

    function run() external {
        vm.startBroadcast();

        manager = new PoolManager(msg.sender);
        weth = new DemoToken("Hook Demo Ether", "hETH");
        dai = new DemoToken("Hook Demo Dollar", "hUSD");
        router = new DemoRouter(IPoolManager(address(manager)));

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, FLAGS, type(ReserveStableHook).creationCode, abi.encode(IPoolManager(address(manager)), 1e18, 1e18, 4, 200, 196, 0.25e18, 500, "Reserve Stable LP", "RSTBL-LP")
        );
        hook = new ReserveStableHook{salt: salt}(IPoolManager(address(manager)), 1e18, 1e18, 4, 200, 196, 0.25e18, 500, "Reserve Stable LP", "RSTBL-LP");
        require(address(hook) == predicted, "hook landed at an unexpected address");

        _openPool();
        vm.stopBroadcast();

        string memory config = string.concat(
            '{"chains":{"31337":{"rpcUrl":"http://127.0.0.1:8545","poolManager":"', vm.toString(address(manager)),
            '","router":"', vm.toString(address(router)),
            '","hook":"', vm.toString(address(hook)),
            '","currency0":"', vm.toString(Currency.unwrap(key.currency0)),
            '","currency1":"', vm.toString(Currency.unwrap(key.currency1)),
            '","poolId":"', vm.toString(PoolId.unwrap(key.toId())),
            '","fee":', vm.toString(uint256(key.fee)),
            ',"tickSpacing":', vm.toString(uint256(uint24(key.tickSpacing))),
            ',"zeroForOne":true,"faucet":true,"demoSwapAmount":"10000000000000000"}}}'
        );
        vm.writeFile("web/local.json", config);
        console2.log("Wrote web/local.json. Now: node web/build.mjs && npx serve web/dist");
        console2.log(config);
    }

    function _openPool() private {
        (Currency currency0, Currency currency1) = address(weth) < address(dai)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(weth)));

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, SQRT_PRICE_1_1);

        weth.claim();
        dai.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 50e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }
}
