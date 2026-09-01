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

    struct SwapResolved {
        uint256 tokenInAmt;
        uint256 tokenOutAmt;
        uint256 issuerFeeAmt;
        uint256 spreadFeeAmt;
        uint256 lpFeeAmt;
    }

    function swap(
        address user,
        address receiver,
        SwapInputs[] calldata inputs,
        ApprovalPermit calldata permit
    ) external;

    function quoteSwap(address user, SwapInputs calldata inputs)
        external
        view
        returns (SwapResolved memory outputs);
}
