| Name               | Type                                         | Slot | Offset | Bytes | Contract                             |
| sendPaused         | bool                                         | 0    | 0      | 1     | src/bridge/CcipBridge.sol:CcipBridge |
| receivePaused      | bool                                         | 0    | 1      | 1     | src/bridge/CcipBridge.sol:CcipBridge |
| moduleSupported    | mapping(uint256 => mapping(uint256 => bool)) | 1    | 0      | 32    | src/bridge/CcipBridge.sol:CcipBridge |
| chainSendPaused    | mapping(uint256 => bool)                     | 2    | 0      | 32    | src/bridge/CcipBridge.sol:CcipBridge |
| chainReceivePaused | mapping(uint256 => bool)                     | 3    | 0      | 32    | src/bridge/CcipBridge.sol:CcipBridge |
| __gap              | uint256[46]                                  | 4    | 0      | 1472  | src/bridge/CcipBridge.sol:CcipBridge |
| peers              | mapping(uint256 => bytes32)                  | 50   | 0      | 32    | src/bridge/CcipBridge.sol:CcipBridge |
