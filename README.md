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

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
