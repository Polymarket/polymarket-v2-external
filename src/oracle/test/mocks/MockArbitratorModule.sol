// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { IArbitratorModule } from "@polymarket-v2/src/oracle/interfaces/IArbitratorModule.sol";
import { IOracleAggregator } from "@polymarket-v2/src/oracle/interfaces/IOracleAggregator.sol";
import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

contract MockArbitratorModule is IArbitratorModule {
    address public aggregator;
    mapping(bytes32 => bool) public isActive;
    mapping(bytes32 => bytes32) public proposedHashes;

    // Records the most recent initializeArbitratorModule call for test assertions.
    uint256 public initCallCount;
    EventId public lastInitEventId;
    bytes public lastInitData;

    constructor(address _aggregator) {
        aggregator = _aggregator;
    }

    function initializeArbitratorModule(EventId eventId, bytes calldata data) external override {
        initCallCount++;
        lastInitEventId = eventId;
        lastInitData = data;
    }

    function onArbitrationTriggered(bytes32 requestId, bytes32 proposedResultHash) external override {
        isActive[requestId] = true;
        proposedHashes[requestId] = proposedResultHash;
    }

    function onArbitrationResolved(bytes32 requestId) external override {
        isActive[requestId] = false;
    }

    function getArbitrationState(bytes32 requestId) external view override returns (bool, bytes32) {
        return (isActive[requestId], proposedHashes[requestId]);
    }

    function resolve(bytes32 _requestId, uint256[] calldata _result) external {
        IOracleAggregator(aggregator).resolveResult(_requestId, _result);
    }
}
