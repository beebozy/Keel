// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

library PriceMath {
    /// @notice Price of token0 in units of token1, scaled by 1e18, adjusted for token decimals.
    /// @dev ratioX96 = (sqrtPriceX96 / 2^96)^2 * 2^96 = raw token1 per raw token0, in Q96.
    ///      Intended for pairs whose price is not extreme (for example stable pairs).
    function sqrtPriceToPrice1e18(uint160 sqrtPriceX96, uint8 dec0, uint8 dec1) internal pure returns (uint256) {
        uint256 ratioX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        return FullMath.mulDiv(ratioX96, 1e18 * (10 ** uint256(dec0)), (uint256(1) << 96) * (10 ** uint256(dec1)));
    }
}
