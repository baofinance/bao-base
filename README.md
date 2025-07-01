# Bao-base

This is a project that can/should be used in all Bao contract projects

## Build status
### foundry
[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-stable.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-stable.yml)
[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-latest.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-latest.yml)
### scripting
[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-scripting.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/CI-test-scripting.yml)

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
