// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Minimal Aave V4 Spoke interface needed to liquidate an unhealthy position.
interface IAaveV4Spoke {
    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool receiveShares
    ) external;
}
