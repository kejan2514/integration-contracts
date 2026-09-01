// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Minimal Multiliquid interface needed by the liquidation executor.
interface IMultiliquidSwap {
    struct ApprovalPermit {
        uint256 deadline;
        bytes signature;
    }

    struct SwapInputs {
        uint256 routeId;
        bytes32 assetInID;
        bytes32 assetOutID;
        bytes32 stablecoinDelegateID;
        uint256 assetInAmt;
        uint256 assetOutAmt;
    }

    function swap(
        address user,
        address receiver,
        SwapInputs[] calldata inputs,
        ApprovalPermit calldata permit
    ) external;
}
