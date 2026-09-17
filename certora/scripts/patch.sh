#!/usr/bin/env bash
set -euo pipefail
echo "Applying PositionManager patch..."
git apply certora/patches/PositionManager_approval.patch
echo "PositionManager patch applied."
echo "Applying NegRiskModule getResult patch..."
git apply certora/patches/NegRiskModule_getResult.patch
echo "NegRiskModule getResult patch applied."
echo "Applying BaseMigrationMixin getResult patch..."
git apply certora/patches/BaseMigrationMixin_getResult.patch
echo "BaseMigrationMixin getResult patch applied."
echo "Applying BridgeBase stripPrefix munge (bridge scenes)..."
git apply certora/patches/BridgeBase_stripPrefix.patch
echo "BridgeBase stripPrefix munge applied."
echo "Applying CcipBridge virtual _transportSend munge (bridge scenes)..."
git apply certora/patches/CcipBridge_virtualTransportSend.patch
echo "CcipBridge virtual _transportSend munge applied."
echo "Applying CombinatorialModule event memory-reset munge (combinatorial event scenes)..."
git apply certora/patches/CombinatorialModule_eventMemoryReset.patch
echo "CombinatorialModule event memory-reset munge applied."
echo "Applying CombinatorialModule _storeLegsFromMemory virtual seam munge (combinatorial scenes)..."
git apply certora/patches/CombinatorialModule_storeLegsVirtual.patch
echo "CombinatorialModule _storeLegsFromMemory virtual seam munge applied."
