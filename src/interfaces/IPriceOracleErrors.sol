// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IPriceOracleErrors
/// @notice Every error a price oracle can revert with — both while producing a price, and while being constructed.
/// @dev A library contributes no ABI of its own, so an error declared only inside a rate, price, or feed library is
///      invisible on the interface of every oracle that reverts with it. Callers then have nothing to decode against
///      unless each interface redeclares it, which is how one error comes to have six homes and drift between them.
///
///      Declaring them here gives one home that a consumer can inherit: an oracle whose implementation uses those
///      libraries inherits this interface (through `IWrappedPriceOracle`), and the errors appear on that oracle's ABI
///      without being copied into it. A library that cannot inherit references them qualified — `IPriceOracleErrors.X`
///      — so the library and every consumer revert with the identical error.
///
///      The construction errors sit at the bottom, grouped but not split into a second interface. They fire once, at
///      deployment, where the runtime ones fire on a live oracle; that distinction is worth seeing while reading, but
///      it is not worth a separate inheritance path, since every oracle wants both.
interface IPriceOracleErrors {
    // ---------------------------------------------------------------------------------------------------------------
    // producing a price: feed reads
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Thrown when feed data is older than the heartbeat allows
    /// @param feed The feed address
    /// @param updatedAt When the feed was last updated
    /// @param currentTime Current block timestamp
    /// @param heartbeat Maximum allowed age in seconds (before tolerance)
    error StaleFeedData(address feed, uint256 updatedAt, uint256 currentTime, uint256 heartbeat);

    /// @notice Thrown when feed has never been updated (updatedAt == 0)
    /// @param feed The feed address
    error FeedNeverUpdated(address feed);

    /// @notice Thrown when normalized price is negative
    /// @param feed The feed address
    /// @param rawAnswer The raw answer from the feed
    error NegativePrice(address feed, int256 rawAnswer);

    /// @notice Thrown when normalized price is zero
    /// @param feed The feed address
    /// @param rawAnswer The raw answer from the feed
    error ZeroPrice(address feed, int256 rawAnswer);

    // ---------------------------------------------------------------------------------------------------------------
    // producing a price: wrapped-asset rates
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Thrown when the rate of a wrapped asset to its underlying is non-positive, or falls outside the
    ///         permitted bounds.
    /// @dev The rate libraries revert rather than clamp, so a rate below the floor halts every priced operation
    ///      instead of reporting a depressed rate.
    /// @param rate The rejected rate, 18 decimals
    error InvalidRate(uint256 rate);

    /// @notice Thrown when the feed backing a rate has not been updated within the permitted age
    /// @param source The address of the rate source
    /// @param updatedAt When the source was last updated
    error StaleRateSource(address source, uint256 updatedAt);

    // ---------------------------------------------------------------------------------------------------------------
    // producing a price: multi-feed composition
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Thrown when a price composed from several feeds is given no feeds at all
    error EmptyFeeds();

    /// @notice Thrown when the arrays describing a multi-feed price disagree in length, or exceed the permitted
    ///         number of feeds.
    /// @param count The rejected count
    error InvalidFeedCount(uint256 count);

    // ---------------------------------------------------------------------------------------------------------------
    // construction: the wiring an oracle refuses to accept
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Thrown when an address argument required by the oracle is zero
    /// @param value The rejected address
    error InvalidAddress(address value);

    /// @notice Thrown when the divisor applied to a feed price is zero
    /// @param divisor The rejected divisor
    error InvalidDivisor(uint256 divisor);

    /// @notice Thrown when an index oracle is given a zero index price
    /// @param indexPrice The rejected index price
    error InvalidIndexPrice(uint256 indexPrice);
}
