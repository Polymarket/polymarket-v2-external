// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    IOOReporter,
    RequestData,
    RequestRulesUpdate
} from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";

/// @notice Mock UMA OOReporter for module unit tests.
contract MockOOReporter is IOOReporter {
    uint256 public registerCallCount;
    bytes32 public lastRequestId;
    bytes32 public lastPriceIdentifier;
    bytes public lastRequestRules;
    uint64 public lastMinimumLiveness;
    uint64 public lastMaximumLiveness;
    uint256 public updateRulesCallCount;
    bytes32 public lastRulesRequestId;
    bytes public lastUpdatedRules;
    bool public override automaticRerequestsEnabled = true;
    bool public forceUpdateRulesRevert;
    bool public forceUpdateRulesEmptyRevert;

    error ForcedUpdateRulesRevert();

    mapping(bytes32 => bool) public registered;
    mapping(bytes32 => bool) public resolved;
    mapping(bytes32 => int256) public resolutions;

    function isRequester(address) external pure override returns (bool) {
        return true;
    }

    function isOracleInitializer(address) external pure override returns (bool) {
        return true;
    }

    function defaultRerequestBudget() external pure override returns (uint256) {
        return 0;
    }

    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external override {
        registerCallCount++;
        registered[requestId] = true;
        lastRequestId = requestId;
        lastPriceIdentifier = priceIdentifier;
        lastRequestRules = requestRules;
        lastMinimumLiveness = minimumLiveness;
        lastMaximumLiveness = maximumLiveness;
    }

    function updateRequestRules(bytes32 requestId, bytes calldata updatedRules) external override {
        if (forceUpdateRulesEmptyRevert) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        if (forceUpdateRulesRevert) revert ForcedUpdateRulesRevert();
        if (!registered[requestId]) revert RequestNotRegistered();
        if (resolved[requestId]) revert RequestAlreadyResolved();

        updateRulesCallCount++;
        lastRulesRequestId = requestId;
        lastUpdatedRules = updatedRules;
    }

    function setForceUpdateRulesRevert(bool _value) external {
        forceUpdateRulesRevert = _value;
    }

    function setForceUpdateRulesEmptyRevert(bool _value) external {
        forceUpdateRulesEmptyRevert = _value;
    }

    function setRegistered(bytes32 requestId, bool isRegistered) external {
        registered[requestId] = isRegistered;
    }

    function isRequestResolved(bytes32 requestId) external view override returns (bool) {
        if (!registered[requestId]) revert RequestNotRegistered();

        return resolved[requestId];
    }

    function getRequestResolution(bytes32 requestId) external view override returns (int256) {
        if (!registered[requestId]) revert RequestNotRegistered();

        return resolutions[requestId];
    }

    function getRequest(bytes32) external pure override returns (RequestData memory request) {
        return request;
    }

    function getRequestId(bytes32, bytes calldata) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function getRequestRulesUpdates(bytes32) external pure override returns (RequestRulesUpdate[] memory updates) {
        return updates;
    }

    function getLatestRequestRulesUpdate(bytes32) external pure override returns (RequestRulesUpdate memory update) {
        return update;
    }

    function getRequestRulesUpdates(bytes32, bytes calldata)
        external
        pure
        override
        returns (RequestRulesUpdate[] memory updates)
    {
        return updates;
    }

    function getLatestRequestRulesUpdate(bytes32, bytes calldata)
        external
        pure
        override
        returns (RequestRulesUpdate memory update)
    {
        return update;
    }

    function getLastRequestRules() external view returns (bytes memory) {
        return lastRequestRules;
    }

    function getLastUpdatedRules() external view returns (bytes memory) {
        return lastUpdatedRules;
    }

    function resolveRequest(bytes32 requestId, int256 resolution) external {
        if (!registered[requestId]) revert RequestNotRegistered();

        resolved[requestId] = true;
        resolutions[requestId] = resolution;
    }

    function initialize(address, address, address, address, address, uint256) external override { }

    function setRequesterEnabled(address, bool) external override { }

    function setOracleInitializerEnabled(address, bool) external override { }

    function setDefaultRerequestBudget(uint256) external override { }

    function setAutomaticRerequestsEnabled(bool enabled) external override {
        automaticRerequestsEnabled = enabled;
    }

    function initializeRequest(bytes32, uint256, uint256, uint64) external override { }

    function rerequest(bytes32, uint256, uint256, uint64) external override { }

    function setRequestRerequestBudget(bytes32, uint256) external override { }

    function claimDeferredPayout(address) external override { }

    function sweep(address, address, uint256) external override { }
}
