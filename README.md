## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

# Keel

A Uniswap v4 hook that manages concentrated liquidity using only validated inputs.
The curator cannot exceed the configured risk limits, the strategy steps down to
simpler execution when an oracle or pool input becomes unreliable, and depositors
can always exit in kind.

## Benchmark architecture (hybrid)

The Vault stores a minimal on-chain epoch snapshot: timestamp, block, holdings value,
share price, whether the price was oracle-valued, drawdown, and the current mode.
Oracle-valued epochs maintain the high-water share price and may trigger a
drawdown step-down; pool-valued epochs never do, so a manipulated pool price cannot
degrade the strategy. Epochs are kept in a fixed-size ring buffer (64 records); older
records remain available through `EpochClosed` events.

Passive LP, HODL and lending returns are **computed off-chain** by the dashboard/indexer
from those records, vault events and public pool state. They are intentionally not
stored in the contract: this keeps gas low and lets the benchmark methodology evolve
without redeploying. `GuardHook.describe()` publishes the live mode and the reason for
the last change, so the interface can show both strategy state and performance.

## Layout

- `src/hooks/GuardHook.sol` — mode control, health checks, validated oracle reads.
- `src/core/Vault.sol` — shares, position, swap-free rebalance, epochs and drawdown.
- `src/libraries/` — range, rebalance, share, price and risk math.
- `test/unit/` — hook, vault, rebalance and epoch tests.

## Testing

```shell
forge test
forge coverage --report summary
```

