// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockFactory {
    mapping(bytes32 => address) public tokenAddress;

    function set(bytes32 uid, address token) external {
        tokenAddress[uid] = token;
    }
}

contract MockFeed {
    uint8 public decimals = 8;
    address public aggregator = address(1);
    int256 public answer = 100e8;
    uint256 public updatedAt;
    uint256 public mode;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 price, uint256 timestamp) external {
        answer = price;
        updatedAt = timestamp;
    }

    function configure(uint8 decimals_, address aggregator_, uint256 mode_) external {
        decimals = decimals_;
        aggregator = aggregator_;
        mode = mode_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == 1) revert("feed offline");
        if (mode == 2) {
            assembly { invalid() }
        }
        if (mode == 3) {
            assembly { return(0, 0) }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Mutation functions exist only in tests; external production interfaces remain minimal.
contract MockStock {
    uint8 public decimals = 18;
    bytes32 public uid;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    bool public paused;
    bool public oraclePause;
    uint256 public oracleMode;
    uint256 public balanceMode;
    uint256 public transferMode;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    constructor(bytes32 uid_) {
        uid = uid_;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function confiscate(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setBalanceMode(uint256 value) external {
        balanceMode = value;
    }

    function setTransferMode(uint256 value) external {
        transferMode = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setOracle(bool paused_, uint256 mode_) external {
        oraclePause = paused_;
        oracleMode = mode_;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function oraclePaused() external view returns (bool) {
        if (oracleMode == 1) revert("oracle unreadable");
        if (oracleMode == 2) {
            assembly { invalid() }
        }
        if (oracleMode == 3) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return oraclePause;
    }

    function balanceOf(address who) external view returns (uint256) {
        uint256 mode = balanceMode;
        if (mode == 1) revert("balance unreadable");
        if (mode == 2) {
            assembly { invalid() }
        }
        if (mode == 3) {
            assembly { return(0, 31) }
        }
        if (mode == 4) {
            assembly { return(0, 64) }
        }
        if (mode == 5) {
            assembly { return(0, 65536) }
        }
        if (mode == 6) {
            assembly { revert(0, 65536) }
        }
        if (mode == 7) {
            uint256 start = gasleft();
            while (start - gasleft() < 43_000) {
                assembly { pop(keccak256(0, 32)) }
            }
        }
        return balances[who];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(!paused && !blocked[from] && !blocked[to], "blocked transfer");
        uint256 mode = transferMode;
        if (mode == 1) revert("transfer offline");
        if (mode == 2) {
            assembly { invalid() }
        }
        if (mode == 3) return false;
        if (mode == 4) return true; // Lies without moving balances.
        if (callback != address(0)) {
            bytes memory result;
            (callbackSucceeded, result) = callback.call(callbackData);
            if (result.length >= 4) callbackError = bytes4(result);
        }
        uint256 debit = mode == 6 ? amount + 1 : amount;
        uint256 credit = mode == 7 ? amount - 1 : amount;
        balances[from] -= debit;
        balances[to] += credit;
        if (mode == 5) {
            assembly { return(0, 0) }
        }
        if (mode == 8) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == 9) {
            assembly {
                mstore(0, 1)
                return(0, 65536)
            }
        }
        if (mode == 10) {
            assembly { revert(0, 65536) }
        }
        if (mode == 11) balanceMode = 1;
        if (mode == 12) {
            // Costs over the redeem frame's budget but succeeds with claim's uncapped frame.
            uint256 start = gasleft();
            while (start - gasleft() < 270_000) {
                assembly { pop(keccak256(0, 32)) }
            }
        }
        return true;
    }
}

contract RevertingRecipient {
    fallback() external {
        revert("must never be called");
    }
}

contract HostileUpgrade {
    fallback() external {
        assembly { invalid() }
    }
}
