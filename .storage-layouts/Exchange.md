| Name                   | Type                                   | Slot | Offset | Bytes | Contract                           |
| paused                 | bool                                   | 0    | 0      | 1     | src/exchange/Exchange.sol:Exchange |
| userPauseBlockInterval | uint256                                | 1    | 0      | 32    | src/exchange/Exchange.sol:Exchange |
| orderStatus            | mapping(bytes32 => struct OrderStatus) | 2    | 0      | 32    | src/exchange/Exchange.sol:Exchange |
| userPausedBlockAt      | mapping(address => uint256)            | 3    | 0      | 32    | src/exchange/Exchange.sol:Exchange |
| preapproved            | mapping(bytes32 => bool)               | 4    | 0      | 32    | src/exchange/Exchange.sol:Exchange |
