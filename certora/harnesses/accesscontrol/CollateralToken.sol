// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CollateralToken as CollateralTokenBase } from "@polymarket-v2/src/collateral/CollateralToken.sol";

/// @title CollateralToken init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `CollateralToken` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract CollateralToken is CollateralTokenBase {
    constructor(address _usdc, address _usdce, address _vault) CollateralTokenBase(_usdc, _usdce, _vault) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}
