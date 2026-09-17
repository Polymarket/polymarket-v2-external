// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title MarketDataRegistry
/// @author Polymarket
/// @notice On-chain registry for market reference data: product specification documents and
///         per-request rules (rule updates).
/// @dev Mixin intended to be inherited by a host contract (the OracleAggregator) that supplies
///      authorization (for product spec writes) and request-state validation (for rule writes)
///      through the two virtual hooks. Storage is held in an ERC-7201 namespaced slot so this
///      mixin can be added to a host without disturbing its existing storage layout. Two data
///      shapes:
///      1. Product specs — maps a product name to a specification URI shared across many markets.
///         Names are matched case-insensitively (ASCII A-Z folded to a-z); the original casing of
///         the first write is preserved for display. Latest pointer lives on-chain; the full
///         changelog is reconstructable from `ProductSpecificationUpdated` events. Written via
///         `setProductSpecification` (gated by `_authorizeMarketDataWrite`).
///      2. Rules — an append-only per-request list of rule updates, mirroring the
///         `requestRulesUpdates` history kept by UMA's OOReporter. The full list lives on-chain.
///         Writes are not exposed directly by the mixin; hosts call the internal `_pushRule`
///         helper after performing their own authorization and `_requireRuleEligible` checks
///         (the OracleAggregator wires rule writes through `updateRequestRules`).
abstract contract MarketDataRegistry {
    /*--------------------------------------------------------------
                                 STRUCTS
    --------------------------------------------------------------*/

    /// @notice The latest specification recorded for a product.
    struct ProductSpecification {
        /// @dev Pointer to the spec document (https URL, ipfs://, ar://, ...).
        string uri;
        /// @dev Canonical product name, pinned on first write.
        string name;
        /// @dev Monotonic write counter; starts at 1, increments on each update. Zero means unset.
        uint64 version;
        /// @dev Block timestamp of the last write.
        uint64 updatedAt;
    }

    /// @notice A single rule entry (rule / rule update) posted for a request.
    struct Rule {
        /// @dev Block timestamp when the rule was posted.
        uint256 timestamp;
        /// @dev Updated prediction market rules / rule text.
        bytes data;
    }

    /// @custom:storage-location erc7201:polymarket.storage.MarketDataRegistry
    struct MarketDataRegistryStorage {
        /// @dev productId => latest product specification.
        mapping(bytes32 productId => ProductSpecification) specs;
        /// @dev requestId => append-only rule history.
        mapping(bytes32 requestId => Rule[]) rules;
    }

    /*--------------------------------------------------------------
                                CONSTANTS
    --------------------------------------------------------------*/

    /// @dev keccak256(abi.encode(uint256(keccak256("polymarket.storage.MarketDataRegistry")) - 1)) & ~0xff.
    bytes32 private constant _MARKET_DATA_REGISTRY_STORAGE =
        0xe6ae852ddc6ee658b8d4a2afa4566ce8f0159b35a162bfcc152d36865d5a0d00;

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when the product name is empty.
    error EmptyProductName();
    /// @notice Thrown when reading the latest rule of a request that has none.
    error RuleUnavailable();

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a product specification is written or updated.
    /// @param productId keccak256 hash of the lowercased product name.
    /// @param name Canonical product name.
    /// @param uri Specification document pointer.
    /// @param version Monotonic write counter for this product.
    /// @param updatedAt Block timestamp of the write.
    event ProductSpecificationUpdated(
        bytes32 indexed productId, string name, string uri, uint64 version, uint64 updatedAt
    );

    /// @notice Emitted when a rule is added for a request.
    /// @param requestId The request identifier.
    /// @param index Zero-based index of the rule in the request's history.
    /// @param timestamp Block timestamp when the rule was posted.
    /// @param data Rule text / updated rules.
    event RuleAdded(bytes32 indexed requestId, uint256 index, uint256 timestamp, bytes data);

    /*--------------------------------------------------------------
                                MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts writes to addresses authorized by the host contract.
    modifier onlyMarketDataWriter() {
        _authorizeMarketDataWrite();
        _;
    }

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Computes the low-level product key for a name.
    /// @dev Case-insensitive: the name is lowercased (ASCII) before hashing.
    /// @param _name Product name.
    /// @return The product key (keccak256 of the lowercased name bytes).
    function productId(string calldata _name) public pure returns (bytes32) {
        return keccak256(bytes(_toLower(_name)));
    }

    /// @notice High-level read: returns the latest specification for a product name.
    /// @dev Lookup is case-insensitive.
    /// @param _name Product name.
    /// @return The latest specification (zero-valued if unset).
    function getProductSpecification(string calldata _name) external view returns (ProductSpecification memory) {
        return _marketDataRegistryStorage().specs[productId(_name)];
    }

    /// @notice Low-level read: returns the latest specification for a product key.
    /// @param _productId Product key from `productId`.
    /// @return The latest specification (zero-valued if unset).
    function getProductSpecificationById(bytes32 _productId) external view returns (ProductSpecification memory) {
        return _marketDataRegistryStorage().specs[_productId];
    }

    /// @notice Returns the full rule history for a request.
    /// @param _requestId The request identifier.
    /// @return The rules in posting order (empty if none).
    function getRules(bytes32 _requestId) external view returns (Rule[] memory) {
        return _marketDataRegistryStorage().rules[_requestId];
    }

    /// @notice Returns a single rule by index without loading the full history.
    /// @dev Lets on-chain consumers read one entry (paired with `getRuleCount`) instead of
    ///      materializing the entire unbounded array via `getRules`.
    /// @param _requestId The request identifier.
    /// @param _index Zero-based index into the request's rule history.
    /// @return The rule at the given index.
    function getRuleAt(bytes32 _requestId, uint256 _index) external view returns (Rule memory) {
        Rule[] storage list = _marketDataRegistryStorage().rules[_requestId];
        if (_index >= list.length) revert RuleUnavailable();
        return list[_index];
    }

    /// @notice Returns the most recent rule for a request.
    /// @param _requestId The request identifier.
    /// @return The latest rule.
    function getLatestRule(bytes32 _requestId) external view returns (Rule memory) {
        Rule[] storage list = _marketDataRegistryStorage().rules[_requestId];
        uint256 count = list.length;
        if (count == 0) revert RuleUnavailable();
        return list[count - 1];
    }

    /// @notice Returns the number of rules recorded for a request.
    /// @param _requestId The request identifier.
    /// @return The rule count.
    function getRuleCount(bytes32 _requestId) external view returns (uint256) {
        return _marketDataRegistryStorage().rules[_requestId].length;
    }

    /*--------------------------------------------------------------
                                EXTERNAL
    --------------------------------------------------------------*/

    /// @notice Writes or updates the specification URI for a product.
    /// @dev The key is case-insensitive; the canonical display name is pinned to the original casing
    ///      of the first write and later writes only update the URI, version, and timestamp.
    /// @param _name Product name.
    /// @param _uri Specification document pointer.
    function setProductSpecification(string calldata _name, string calldata _uri) external onlyMarketDataWriter {
        if (bytes(_name).length == 0) revert EmptyProductName();

        bytes32 id = productId(_name);
        ProductSpecification storage spec = _marketDataRegistryStorage().specs[id];

        if (spec.version == 0) spec.name = _name;
        spec.uri = _uri;
        uint64 newVersion = spec.version + 1;
        uint64 timestamp = uint64(block.timestamp);
        spec.version = newVersion;
        spec.updatedAt = timestamp;

        emit ProductSpecificationUpdated(id, spec.name, _uri, newVersion, timestamp);
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Authorizes a market-data write. Hosts override to enforce their own roles.
    function _authorizeMarketDataWrite() internal view virtual;

    /// @dev Validates that a request may receive a rule. A host may establish request existence
    ///      before calling this hook and use the hook only for lifecycle eligibility.
    function _requireRuleEligible(bytes32 _requestId) internal view virtual;

    /// @dev Appends a rule to the request's history without any authorization or eligibility
    ///      checks. Callers are responsible for performing those checks (in particular calling
    ///      `_requireRuleEligible` before appending). Used by host contracts to record a rule
    ///      update as part of a larger gated operation (e.g. forwarding rule updates to reporter
    ///      modules in `OracleAggregator.updateRequestRules`).
    /// @param _requestId The request identifier.
    /// @param _data Rule text / updated rules.
    function _pushRule(bytes32 _requestId, bytes calldata _data) internal {
        Rule[] storage list = _marketDataRegistryStorage().rules[_requestId];
        uint256 index = list.length;
        uint256 timestamp = block.timestamp;
        list.push(Rule({ timestamp: timestamp, data: _data }));

        emit RuleAdded(_requestId, index, timestamp, _data);
    }

    /// @dev Lowercases the ASCII A-Z characters of a name; other bytes (incl. non-ASCII) pass through.
    /// @param _name Product name.
    /// @return The lowercased name.
    function _toLower(string calldata _name) internal pure returns (string memory) {
        bytes memory b = bytes(_name);
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5A) b[i] = bytes1(c + 32);
        }
        return string(b);
    }

    /// @dev Returns a pointer to the ERC-7201 namespaced storage struct.
    /// @return $ The registry storage struct.
    function _marketDataRegistryStorage() private pure returns (MarketDataRegistryStorage storage $) {
        assembly {
            $.slot := _MARKET_DATA_REGISTRY_STORAGE
        }
    }
}
