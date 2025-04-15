ether = 1e18

from decimal import Decimal


def to_wei(value: Decimal) -> int:
    return int(value * Decimal(ether))


def from_wei(value: int) -> Decimal:
    return Decimal(value) / Decimal(ether)


def to_hex(value: int) -> str:
    return hex(value)


def to_hex(value: Decimal) -> str:
    return hex(to_wei(value))
