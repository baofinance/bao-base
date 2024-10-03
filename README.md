# Baobase

This is a project that can/should be used in all Bao contracts

## Usage

Install this project using

```shell
$ forge install baofinance\baobase
```

add this to `remappings.txt`

    @bao/=lib/baobase/src/


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

```shell
$ yarn build
```

```shell
$ yarn test
```

```shell
$ yarn fmt
```

```shell
$ yarn gas
```

```
