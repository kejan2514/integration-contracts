// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Minimal Aave V3 single-asset flash-loan receiver interface.
interface IAaveV3FlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
