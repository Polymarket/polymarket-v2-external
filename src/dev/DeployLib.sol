// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { vm } from "./Vm.sol";

library DeployLib {
    function _deployCode(string memory _what) internal returns (address addr) {
        return _deployCode(_what, "");
    }

    function _deployCode(string memory _what, bytes memory _args) internal returns (address addr) {
        bytes memory bytecode = abi.encodePacked(vm.getCode(_what), _args);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function deployConditionalTokens() internal returns (address) {
        address deployment = _deployCode("artifacts/ConditionalTokens.json");
        if (deployment == address(0)) revert("[DeployLib] deployConditionalTokens failed");
        vm.label(deployment, "ConditionalTokens");
        return deployment;
    }

    function deployNegRiskAdapter(address _ctf, address _collateral, address _vault) internal returns (address) {
        bytes memory args = abi.encode(_ctf, _collateral, _vault);
        address deployment = _deployCode("artifacts/NegRiskAdapter.json", args);
        if (deployment == address(0)) revert("[DeployLib] deployNegRiskAdapter failed");
        vm.label(deployment, "NegRiskAdapter");
        return deployment;
    }

    function deployCtfExchange(address _collateral, address _ctf, address _proxyFactory, address _safeFactory)
        internal
        returns (address)
    {
        bytes memory args = abi.encode(_collateral, _ctf, _proxyFactory, _safeFactory);
        address deployment = _deployCode("artifacts/CTFExchange.json", args);
        if (deployment == address(0)) revert("[DeployLib] deployCtfExchange failed");
        vm.label(deployment, "CtfExchange");
        return deployment;
    }

    function deployUmaCtfAdapterV3(address _ctf, address _finder) internal returns (address) {
        bytes memory args = abi.encode(_ctf, _finder);
        address deployment = _deployCode("artifacts/UmaCtfAdapterV31.json", args);
        vm.label(deployment, "UmaCtfAdapterV3");
        return deployment;
    }
}
