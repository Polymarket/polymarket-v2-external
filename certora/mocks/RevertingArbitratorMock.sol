// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IArbitratorModule } from "@polymarket-v2/src/oracle/interfaces/IArbitratorModule.sol";
import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title RevertingArbitratorMock
/// @notice An arbitrator module whose lifecycle hooks always revert.
/// @dev Exists for ORACLE-ARB-01 ("arbitrator hook failures never brick the lifecycle"). The
///      aggregator reaches `onArbitrationTriggered` / `onArbitrationResolved` through a low-level
///      `.call` whose failure it deliberately swallows (`OracleAggregator.sol:459-461`, `:669-672`),
///      so the adversarial branch of that design can only be exercised if some scene contract
///      actually reverts. `certora/mocks/BinaryReporterTargetMock.sol`'s arbitrator counterpart —
///      `src/oracle/test/mocks/MockArbitratorModule.sol` — never reverts, so with only that mock in
///      the DISPATCH list the failure branch is unreachable and the property is vacuous.
///
///      `initializeArbitratorModule` does NOT revert: it is called from `initializeRequest` /
///      `setArbitratorModule` as a plain high-level call whose revert propagates by design, and a
///      reverting initializer would simply make every request that configures this arbitrator
///      unbuildable, removing the scene contract from the interesting traces.
contract RevertingArbitratorMock is IArbitratorModule {
    /// @notice Thrown by both arbitration hooks.
    error ArbitratorRefuses();

    /// @inheritdoc IArbitratorModule
    function initializeArbitratorModule(EventId, bytes calldata) external override { }

    /// @inheritdoc IArbitratorModule
    function onArbitrationTriggered(bytes32, bytes32) external pure override {
        revert ArbitratorRefuses();
    }

    /// @inheritdoc IArbitratorModule
    function onArbitrationResolved(bytes32) external pure override {
        revert ArbitratorRefuses();
    }

    /// @inheritdoc IArbitratorModule
    function getArbitrationState(bytes32) external pure override returns (bool, bytes32) {
        return (false, bytes32(0));
    }
}
