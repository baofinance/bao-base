### ![logo](doc/bao-harbor.jpg)

# Bao-base

This is a project that can/should be used in all Bao contract projects.

## Build status

### foundry

[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-stable.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-stable.yml)
<br>
[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-latest.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-latest.yml)

### scripting

[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-scripting.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-scripting.yml)

## Deployment Framework

Bao-base has base classes for foundry scripting based deployment - basically for every contract deployable there is a contract that configures it.

It uses `lib/bao-factory` for deterministic CREATE3 deployments. See the [bao-factory README](lib/bao-factory/README.md) for deployment operations.

## BaoOwnable and BaoRoles

These contracts provide ownership and role-based access control but **do not behave like OpenZeppelin's equivalents**.

### BaoOwnable

- Ownership transfer is **one-time only** and must complete within 1 hour
- Uses a two-phase pattern: `deployerOwner` (initial setup) → `pendingOwner` (final owner)
- `_initializeOwner(deployerOwner, pendingOwner)` sets both; `transferOwnership(pendingOwner)` completes it
- Once transferred, ownership cannot be changed again
- Supports ERC165 interface detection

### BaoRoles

- Based on Solady's `OwnableRoles` but decoupled from the ownable mechanism
- Provides `grantRoles`, `revokeRoles`, `hasAllRoles`, `hasAnyRole`
- Role constants are defined as `_ROLE_0`, `_ROLE_1`, etc. (bitmask pattern)
- Mixes with `BaoOwnable` or `BaoOwnableTransferrable` via `BaoOwnableRoles`

Variants: `BaoFixedOwnable` (hardcoded owner), `BaoOwnableTransferrable` (allows later transfers).

## MintableBurnableERC20

A UUPS-upgradeable ERC20 with role-gated minting and burning.

- Uses `BaoOwnableRoles` for access control
- `MINTER_ROLE` and `BURNER_ROLE` constants for role checks
- Includes ERC20Permit support
- ERC165 interface detection for `IMintable`, `IBurnable`, `IBurnableFrom`

## BaoPauser

A minimal UUPS contract used for emergency pausing via proxy upgrade.

- Upgrade a proxy to `BaoPauser_v1` to disable all functionality
- Uses `BaoFixedOwnable` with hardcoded Harbor multisig owner
- Upgrade back to the original implementation to restore functionality

## TokenHolder

Abstract contract for sweeping tokens from a contract.

- Provides `sweep(token, amount, receiver)` to recover stuck tokens
- Uses reentrancy guard and owner check by default
- Override `_checkSweeper()` to customize access control

## BaoTest - a base contract for foundry tests

Shared test utilities for Foundry suites. Extend `BaoTest` instead of `Test` to get:

- **`assertApprox`** - pytest-style approximate assertions with absolute and optional relative tolerances
- **`isApprox`** - boolean version for use in conditionals
- BaoFactory deployment helpers and labeled addresses

```solidity
assertApprox(actual, expected, 1e15);           // 0.001 absolute tolerance
assertApprox(actual, expected, 0, 0.01 ether);  // 1% relative tolerance
```

## Usage

Install this project using

```shell
$ forge install baofinance/bao-base
```

add this to `remappings.txt`

```
@bao/=lib/bao-base/src/
```

# config files

You can/should use config files used here for your project

## solhint

in `package.json`

```json
{
  "scripts": {
    "lint": "solhint 'src/**/*.sol' --config ./lib/bao-base/.solhint.json --disc"
  }
}
```

## slither

in `package.json`

```json
{
  "scripts": {
    "slither": "echo $(which slither) version=$(slither --version) && slither . --config ./lib/bao-base/slither.config.json --exclude-dependencies --fail-pedantic",
    "install:slither": "pip3 install slither-analyzer --upgrade"
  }
}
```

There is no slither npm package, so you have to install it manually by:

```shell
$ yarn install:slither
```

do it this way so the github actions can install slither too.

## prettier

in `package.json`

```json
{
  "scripts": {
    "prettier": "prettier --log-level warn '{src,test,script}/**/*.sol'",
    "fmt": "yarn prettier --write",
    "fmt:check": "yarn prettier --check"
  },
  "prettier": "./lib/bao-base/prettier.config.js"
}
```

The [prettier vscode extension](https://marketplace.visualstudio.com/items?itemName=esbenp.prettier-vscode) can also access the same config this way.

# github actions

This git module also provides a standard build and test for solidity.
Put this in your `.github/workflows/<name>.yml`

```yml
name: CI

on:
  push:
  pull_request:
  workflow_dispatch:

jobs:
  call_bao-foundry-project:
    uses: baofinance/bao-base/.github/workflows/bao-foundry-project.yml@main
```

This will call into bao-base's workflow which will execute a standard set of build and test commands.
You will need to set up you `package.json` so that it has the following:

```json
{
  "scripts": {
    "test": ...,
    "coverage": ...,
    "sizes": ...,
    "gas": ...,
    "fmt:check": ...,
    "lint": ...
  }
}
```

### running it all

This workflow can be executed locally. Add this to your `package.json`

```json
{
  "scripts": {
    "pre-push": "gh act -P ubuntu-latest=-self-hosted",
    "install:act": "gh extension install https://github.com/nektos/gh-act"
  }
}
```

There is no npm package for this, so you have to install it manually by:

```shell
$ yarn install:act
```

The local execution uses your .env file which is not available on github so you need to add any API keys into you github repo.

# Development

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

### build and test

```shell
$ yarn              # install node dependencies
$ yarn test         # build and run tests, also installs git submodules
$ yarn coverage     # generates test coverage.txt - this should go in git
$ yarn sizes        # generates test sizes.txt - this should go in git
$ yarn gas          # generates gas.txt - this should go in git
```

We store those file `coverage.txt`, `sizes.txt`, and `gas.txt` in git so that they can be monitored for regressions. Watch this space for something better than the textual diff that git gives you.

### formatting & static checking

```shell
$ yarn fmt      # uses prettier
$ yarn slither
$ yarn lint     # uses solhint
```

### running it all

You can run all the commands above before you `commit` and certainly before you `push` by:

```shell
$ yarn pre-push
```
