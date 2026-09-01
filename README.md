# Uniform Labs Integration Contracts

Standalone Solidity integrations for Multiliquid.

## Aave V4 flash-liquidation executor

`AaveV4MultiliquidFlashLiquidator` is an example executor for a solver that does not hold the
debt asset before submitting an Aave V4 liquidation. It atomically:

1. borrows the debt asset with Aave V3 `flashLoanSimple`;
2. repays the unhealthy user's Aave V4 debt through the Spoke's `liquidationCall`;
3. receives the underlying collateral (`receiveShares = false`);
4. sells that collateral through Multiliquid's exact-input RWA-to-stablecoin route;
5. approves the Aave V3 Pool to pull the flash-loan principal and premium; and
6. transfers the remaining debt-asset profit to the executor owner.

Every step occurs in one transaction. A failure in the liquidation, swap, minimum-output check,
minimum-profit check, or flash-loan repayment reverts the entire flow.

The deployment is intentionally pair-specific. Its constructor fixes the flash lender, Aave V4
Spoke, Multiliquid swap and delegate, collateral and debt tokens, and Multiliquid asset IDs. The
owner is the only account allowed to start an execution.

### Assumptions and limitations

- The flash lender is an Aave V3 Pool with sufficient liquidity in the Aave V4 debt asset. Aave V4
  supplies the liquidation endpoint, but this example does not assume that V4 supplies flash loans.
- The Multiliquid swap must pay out the same token borrowed from the flash lender. An intermediate
  stablecoin requires another trusted swap leg or a separate executor implementation.
- The Multiliquid route is route ID `2`, RWA-to-stablecoin exact-input.
- The executor must satisfy any transfer, investor, or allowlist requirements of the RWA token and
  Multiliquid route.
- The owner must calculate economically safe `minCollateralReceived`, `minDebtAssetOut`, and
  `minProfit` values before submitting an execution. Those bounds protect the transaction; the
  contract does not discover positions or calculate profitability.
- This repository is a reference implementation and has not been audited. Do not deploy it with
  production funds without protocol-specific integration tests and an independent security review.

## Development

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then clone with
submodules:

```sh
git clone --recurse-submodules git@github.com:uniformlabs/integration-contracts.git
cd integration-contracts
```

For an existing clone:

```sh
git submodule update --init --recursive
```

Build, format, lint, and test:

```sh
forge build
forge fmt --check
forge lint
forge test
```

The project pins Solidity `0.8.30`, Forge Standard Library, and OpenZeppelin Contracts through the
Foundry lockfile and Git submodules.

### XAUt Aave V4 mainnet-fork integration

The opt-in fork test uses XAUt (`0x68749665FF8D2d112Fa859AA293F07A622782F38`) as real collateral
in Aave V4's deployed Ethereum Gold Spoke. It exercises live Ethereum contracts for:

- a one-XAUt supply, near-limit USDC borrow, health-factor calculation, interest accrual, and
  liquidation in the Aave V4 Gold Spoke;
- XAUt pricing from the same Chainlink XAU/USD feed configured in the Gold Spoke;
- the Aave V3 Pool's USDC flash loan and premium repayment; and
- the deployed Multiliquid swap and Uniform Labs USDC Delegate settlement path.

XAUt is not registered in the deployed Multiliquid contracts at the pinned block. The test models
that prospective integration by impersonating the existing authorized mainnet accounts and using
the production configuration functions to:

- register the fork-only asset ID `keccak256("XAUt")` with no token-level whitelist adapter;
- install a fork-deployed Chainlink adapter that scales the eight-decimal XAU/USD answer to WAD and
  enforces a 25-hour maximum age;
- whitelist XAUt on the Uniform Labs USDC Delegate; and
- set its RWA-to-USDC discount to 25 bps.

No Aave contract, oracle response, liquidation, or health-factor calculation is mocked. The test
funds the new borrower with XAUt and adds USDC to the existing delegate custody using Foundry's
`deal` helper. It then borrows at 99.999% of the position's calculated limit and advances fork time
in one-hour steps until real USDC interest makes the position liquidatable. A snapshot-only
preflight through the real Spoke determines the exact collateral and debt rounding before the
flash-liquidation transaction is executed and asserted.

Start a pinned Anvil fork in one terminal using an archive-capable Ethereum RPC:

```sh
export ETHEREUM_RPC_URL=https://your-ethereum-rpc.example
anvil \
  --fork-url "$ETHEREUM_RPC_URL" \
  --fork-block-number 25883433 \
  --chain-id 1
```

Run the test in another terminal:

```sh
RUN_MAINNET_FORK_TESTS=true \
MAINNET_FORK_RPC_URL=http://127.0.0.1:8545 \
MAINNET_FORK_BLOCK=25883433 \
forge test \
  --match-path test/fork/AaveV4MultiliquidFlashLiquidatorMainnetFork.t.sol \
  -vv
```

To exercise current mainnet state instead, omit Anvil's `--fork-block-number` argument and set
`MAINNET_FORK_BLOCK=0` for the Forge command. The ordinary test suite skips this integration unless
`RUN_MAINNET_FORK_TESTS=true` is set.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
