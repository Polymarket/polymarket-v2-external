// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Exchange as ExchangeBase } from "@polymarket-v2/src/exchange/Exchange.sol";

/// @title Exchange init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `Exchange` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract Exchange is ExchangeBase {
    constructor(
        address _positionManager,
        address _combinatorialModule,
        address _feeReceiver,
        uint256 _maxFeeRate,
        address _proxyFactory,
        address _safeFactory,
        bytes32 _proxyBytecodeHash,
        bytes32 _safeBytecodeHash
    ) ExchangeBase(
            _positionManager,
            _combinatorialModule,
            _feeReceiver,
            _maxFeeRate,
            _proxyFactory,
            _safeFactory,
            _proxyBytecodeHash,
            _safeBytecodeHash
        ) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}
