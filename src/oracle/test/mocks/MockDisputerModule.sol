// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { IDisputerModule } from "@polymarket-v2/src/oracle/interfaces/IDisputerModule.sol";
import { IOracleAggregator } from "@polymarket-v2/src/oracle/interfaces/IOracleAggregator.sol";
import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

contract MockDisputerModule is IDisputerModule {
    address public aggregator;
    mapping(EventId => mapping(address => bool)) public authorizedDisputers;

    constructor(address _aggregator) {
        aggregator = _aggregator;
    }

    function initializeDisputerModule(EventId eventId, bytes calldata data) external override {
        address[] memory disputers = abi.decode(data, (address[]));
        for (uint256 i = 0; i < disputers.length; ++i) {
            authorizedDisputers[eventId][disputers[i]] = true;
        }
    }

    function getDisputeBond(EventId) external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function dispute(bytes32 _conditionId) external {
        IOracleAggregator(aggregator).disputeResult(_conditionId);
    }
}
