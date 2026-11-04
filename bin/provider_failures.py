"""Whether a failure forge or cast reports is the RPC provider's.

forge and cast reach a chain through the same transport, so they report the provider's failures in the same
words: its JSON-RPC error ("server returned an error response"), the retries on its refusals exhausted ("Max
retries exceeded"), and a fork backend's read failing ("Failed to send/recv"). Every tool that runs a
provider's failure again decides with this, so they agree on which failures those are.

A call the node itself reverts comes back as the same JSON-RPC error ("error code 3: execution reverted"), so
cast's report of such a revert reads as the provider's too. A forked test's revert does not: forge executes
the call itself, and reports the revert in its own words.
"""

# in forge 1.9.0's and cast 1.9.0's words
_WORDS = ("server returned an error response", "Max retries exceeded", "Failed to send/recv")


def reads_as_the_providers(message: str) -> bool:
    """Whether `message` reads as the provider's failure."""
    return any(words in message for words in _WORDS)
