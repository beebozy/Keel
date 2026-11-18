// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";

/// @notice Controllable oracle for tests and testnet demos. NOT a real price source.
contract MockOracleAdapter is IOracleAdapter {
    uint256 public priceX18;
    uint256 public updatedAt;
    bool public valid = true;
    bool public shouldRevert;
    uint8 public malformed; // 0 normal, 1 empty return, 2 one-word return, 3 bool word = 2
    address public immutable owner;

    error NotOwner();
    error OracleDown();

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        priceX18 = initialPrice;
        updatedAt = block.timestamp;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Sets the price and stamps it with the current time.
    function setPrice(uint256 p) external onlyOwner {
        priceX18 = p;
        updatedAt = block.timestamp;
    }

    function setPriceAt(uint256 p, uint256 t) external onlyOwner {
        priceX18 = p;
        updatedAt = t;
    }

    function setValid(bool v) external onlyOwner {
        valid = v;
    }

    function setRevert(bool r) external onlyOwner {
        shouldRevert = r;
    }

    function setMalformed(uint8 kind) external onlyOwner {
        malformed = kind;
    }

    function getPrice() external view returns (StrategyTypes.OraclePrice memory) {
        if (shouldRevert) revert OracleDown();
        uint256 p = priceX18;
        uint256 t = updatedAt;
        uint8 kind = malformed;
        if (kind == 1) {
            assembly {
                return(0, 0)
            }
        }
        if (kind == 2) {
            assembly {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        if (kind == 3) {
            assembly {
                mstore(0x00, p)
                mstore(0x20, t)
                mstore(0x40, 2)
                return(0x00, 0x60)
            }
        }
        return StrategyTypes.OraclePrice({priceX18: p, updatedAt: t, valid: valid});
    }
}
