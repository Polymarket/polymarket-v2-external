#!/usr/bin/env bash
echo "Unapplying CombinatorialModule event memory-reset munge..."
git apply -R certora/patches/CombinatorialModule_eventMemoryReset.patch
echo "CombinatorialModule event memory-reset munge unapplied."
echo "Unapplying CombinatorialModule _storeLegsFromMemory virtual seam munge..."
git apply -R certora/patches/CombinatorialModule_storeLegsVirtual.patch
echo "CombinatorialModule _storeLegsFromMemory virtual seam munge unapplied."
echo "Unapplying CcipBridge virtual _transportSend munge..."
git apply -R certora/patches/CcipBridge_virtualTransportSend.patch
echo "CcipBridge virtual _transportSend munge unapplied."
echo "Unapplying BridgeBase stripPrefix munge..."
git apply -R certora/patches/BridgeBase_stripPrefix.patch
echo "BridgeBase stripPrefix munge unapplied."
echo "Unapplying BaseMigrationMixin getResult patch..."
git apply -R certora/patches/BaseMigrationMixin_getResult.patch
echo "BaseMigrationMixin getResult patch unapplied."
echo "Unapplying NegRiskModule getResult patch..."
git apply -R certora/patches/NegRiskModule_getResult.patch
echo "NegRiskModule getResult patch unapplied."
echo "Unapplying PositionManager patch..."
git apply -R certora/patches/PositionManager_approval.patch
echo "PositionManager patch unapplied."
