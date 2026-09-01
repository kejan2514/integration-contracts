// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Minimal Aave V3 Pool interface needed by the liquidation executor.
interface IAaveV3FlashLoanPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
