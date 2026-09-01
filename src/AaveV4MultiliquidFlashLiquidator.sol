// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveV3FlashLoanPool} from "src/interfaces/IAaveV3FlashLoanPool.sol";
import {IAaveV3FlashLoanSimpleReceiver} from "src/interfaces/IAaveV3FlashLoanSimpleReceiver.sol";
import {IAaveV4Spoke} from "src/interfaces/IAaveV4Spoke.sol";
import {IMultiliquidSwap} from "src/interfaces/IMultiliquidSwap.sol";

/// @title AaveV4MultiliquidFlashLiquidator
/// @notice Solver contract that finances an Aave V4 liquidation with an Aave V3 flash loan,
/// sells the received underlying collateral through Multiliquid, and repays the flash loan.
/// @dev This example intentionally supports one immutable collateral/debt pair and one immutable
/// Multiliquid delegate. A production solver should additionally model token-specific compliance,
/// private transaction submission, oracle freshness, and chain-specific lender configuration.
contract AaveV4MultiliquidFlashLiquidator is Ownable, IAaveV3FlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    uint256 private constant RWA_TO_STABLE_EXACT_IN = 2;

    uint8 private constant EXECUTION_IDLE = 0;
    uint8 private constant EXECUTION_REQUESTED = 1;
    uint8 private constant EXECUTION_CALLBACK = 2;
    uint8 private constant EXECUTION_COMPLETE = 3;

    struct ExecutionParams {
        uint256 collateralReserveId;
        uint256 debtReserveId;
        address borrower;
        uint256 debtToCover;
        uint256 flashLoanAmount;
        uint256 minCollateralReceived;
        uint256 minDebtAssetOut;
        uint256 minProfit;
        uint16 referralCode;
    }

    struct CallbackAccounting {
        uint256 debtRepaid;
        uint256 collateralReceived;
        uint256 debtAssetReceived;
        uint256 repayment;
        uint256 projectedProfit;
    }

    IAaveV3FlashLoanPool public immutable FLASH_LOAN_POOL;
    IAaveV4Spoke public immutable LIQUIDATION_SPOKE;
    IMultiliquidSwap public immutable MULTILIQUID_SWAP;
    IERC20 public immutable COLLATERAL_ASSET;
    IERC20 public immutable DEBT_ASSET;
    address public immutable MULTILIQUID_DELEGATE;
    bytes32 public immutable COLLATERAL_ASSET_ID;
    bytes32 public immutable DEBT_ASSET_ID;
    bytes32 public immutable STABLECOIN_DELEGATE_ID;

    uint8 private _executionState;
    bytes32 private _activeExecutionHash;

    event LiquidationAndSwap(
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralReceived,
        uint256 debtAssetReceived,
        uint256 flashLoanPremium,
        uint256 projectedProfit
    );
    event ProfitPaid(address indexed recipient, uint256 amount);
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);

    error InvalidAddress();
    error InvalidAssetPair();
    error InvalidBorrower();
    error InvalidExecutionAmount();
    error ExecutionInProgress();
    error InvalidFlashLoanCallback();
    error FlashLoanCallbackIncomplete();
    error UnexpectedFlashLoanBalance(uint256 actual, uint256 expected);
    error UnexpectedDebtBalance();
    error InsufficientCollateralReceived(uint256 actual, uint256 minimum);
    error UnexpectedCollateralBalance(uint256 actual, uint256 expected);
    error InsufficientDebtAssetReceived(uint256 actual, uint256 minimum);
    error InsufficientRepaymentBalance(uint256 actual, uint256 required);
    error InsufficientProfit(uint256 actual, uint256 minimum);

    constructor(
        address owner_,
        IAaveV3FlashLoanPool flashLoanPool_,
        IAaveV4Spoke liquidationSpoke_,
        IMultiliquidSwap multiliquidSwap_,
        IERC20 collateralAsset_,
        IERC20 debtAsset_,
        address multiliquidDelegate_,
        bytes32 collateralAssetId_,
        bytes32 debtAssetId_,
        bytes32 stablecoinDelegateId_
    ) Ownable(owner_) {
        if (
            address(flashLoanPool_) == address(0) || address(liquidationSpoke_) == address(0)
                || address(multiliquidSwap_) == address(0)
                || address(collateralAsset_) == address(0) || address(debtAsset_) == address(0)
                || multiliquidDelegate_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            address(collateralAsset_) == address(debtAsset_) || collateralAssetId_ == bytes32(0)
                || debtAssetId_ == bytes32(0) || stablecoinDelegateId_ == bytes32(0)
        ) {
            revert InvalidAssetPair();
        }

        FLASH_LOAN_POOL = flashLoanPool_;
        LIQUIDATION_SPOKE = liquidationSpoke_;
        MULTILIQUID_SWAP = multiliquidSwap_;
        COLLATERAL_ASSET = collateralAsset_;
        DEBT_ASSET = debtAsset_;
        MULTILIQUID_DELEGATE = multiliquidDelegate_;
        COLLATERAL_ASSET_ID = collateralAssetId_;
        DEBT_ASSET_ID = debtAssetId_;
        STABLECOIN_DELEGATE_ID = stablecoinDelegateId_;
    }

    /// @notice Flash-finances one liquidation and sends realized debt-asset profit to the owner.
    /// @dev `debtToCover` cannot exceed the flash-loan principal, ensuring that the operation does
    /// not consume debt tokens already held by this contract.
    function executeLiquidation(ExecutionParams calldata params)
        external
        onlyOwner
        returns (uint256 profit)
    {
        if (_executionState != EXECUTION_IDLE) revert ExecutionInProgress();
        if (params.borrower == address(0) || params.borrower == address(this)) {
            revert InvalidBorrower();
        }
        if (
            params.debtToCover == 0 || params.flashLoanAmount == 0
                || params.debtToCover > params.flashLoanAmount
        ) {
            revert InvalidExecutionAmount();
        }

        uint256 debtBalanceBefore = DEBT_ASSET.balanceOf(address(this));
        bytes memory callbackParams = abi.encode(params, debtBalanceBefore);

        // These are transient callback authorization values, not administrative access changes.
        // forge-lint: disable-next-line(missing-events-access-control)
        _executionState = EXECUTION_REQUESTED;
        // forge-lint: disable-next-line(missing-events-access-control)
        _activeExecutionHash = keccak256(callbackParams);

        // The execution state is intentionally advanced by the authenticated synchronous callback.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        FLASH_LOAN_POOL.flashLoanSimple(
            address(this),
            address(DEBT_ASSET),
            params.flashLoanAmount,
            callbackParams,
            params.referralCode
        );

        if (_executionState != EXECUTION_COMPLETE) revert FlashLoanCallbackIncomplete();

        // Aave pulls repayment after executeOperation returns. Clear its residual approval before
        // paying profit or making the contract available for another execution.
        DEBT_ASSET.forceApprove(address(FLASH_LOAN_POOL), 0);

        uint256 debtBalanceAfter = DEBT_ASSET.balanceOf(address(this));
        if (debtBalanceAfter < debtBalanceBefore) revert UnexpectedDebtBalance();

        profit = debtBalanceAfter - debtBalanceBefore;
        if (profit < params.minProfit) revert InsufficientProfit(profit, params.minProfit);

        if (profit > 0) {
            DEBT_ASSET.safeTransfer(owner(), profit);
        }

        _activeExecutionHash = bytes32(0);
        _executionState = EXECUTION_IDLE;

        // Only immutable trusted endpoints can reach this point while the state machine is active.
        // forge-lint: disable-next-item(reentrancy-events)
        emit ProfitPaid(owner(), profit);
    }

    /// @inheritdoc IAaveV3FlashLoanSimpleReceiver
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata callbackParams
    ) external returns (bool) {
        if (
            msg.sender != address(FLASH_LOAN_POOL) || initiator != address(this)
                || asset != address(DEBT_ASSET) || _executionState != EXECUTION_REQUESTED
                || keccak256(callbackParams) != _activeExecutionHash
        ) {
            revert InvalidFlashLoanCallback();
        }

        (ExecutionParams memory params, uint256 debtBalanceBefore) =
            abi.decode(callbackParams, (ExecutionParams, uint256));
        if (amount != params.flashLoanAmount) revert InvalidFlashLoanCallback();

        // This is a transient callback guard, not an administrative access change.
        // forge-lint: disable-next-line(missing-events-access-control)
        _executionState = EXECUTION_CALLBACK;

        CallbackAccounting memory accounting;

        _validateFlashLoanBalance(debtBalanceBefore, amount);
        (accounting.debtRepaid, accounting.collateralReceived) = _liquidate(params);
        accounting.debtAssetReceived =
            _sellCollateral(accounting.collateralReceived, params.minDebtAssetOut);
        accounting.repayment = amount + premium;

        uint256 debtBalanceAfterSwap = DEBT_ASSET.balanceOf(address(this));
        uint256 repaymentBalance = debtBalanceBefore + accounting.repayment;
        if (debtBalanceAfterSwap < repaymentBalance) {
            revert InsufficientRepaymentBalance(debtBalanceAfterSwap, repaymentBalance);
        }

        accounting.projectedProfit = debtBalanceAfterSwap - repaymentBalance;
        if (accounting.projectedProfit < params.minProfit) {
            revert InsufficientProfit(accounting.projectedProfit, params.minProfit);
        }
        DEBT_ASSET.forceApprove(address(FLASH_LOAN_POOL), accounting.repayment);
        _executionState = EXECUTION_COMPLETE;

        // Callback authentication and immutable endpoints protect event provenance.
        // forge-lint: disable-next-item(reentrancy-events)
        emit LiquidationAndSwap(
            params.borrower,
            accounting.debtRepaid,
            accounting.collateralReceived,
            accounting.debtAssetReceived,
            premium,
            accounting.projectedProfit
        );

        return true;
    }

    /// @notice Recovers tokens accidentally sent to this executor while no liquidation is active.
    function rescueToken(IERC20 token, address recipient, uint256 amount) external onlyOwner {
        if (_executionState != EXECUTION_IDLE) revert ExecutionInProgress();
        if (recipient == address(0)) revert InvalidAddress();

        token.safeTransfer(recipient, amount);
        emit TokenRescued(address(token), recipient, amount);
    }

    function _validateFlashLoanBalance(uint256 debtBalanceBefore, uint256 amount) private view {
        uint256 expectedFlashBalance = debtBalanceBefore + amount;
        uint256 actualFlashBalance = DEBT_ASSET.balanceOf(address(this));
        if (actualFlashBalance != expectedFlashBalance) {
            revert UnexpectedFlashLoanBalance(actualFlashBalance, expectedFlashBalance);
        }
    }

    function _liquidate(ExecutionParams memory params)
        private
        returns (uint256 debtRepaid, uint256 collateralReceived)
    {
        uint256 debtBalanceBefore = DEBT_ASSET.balanceOf(address(this));
        uint256 collateralBalanceBefore = COLLATERAL_ASSET.balanceOf(address(this));

        DEBT_ASSET.forceApprove(address(LIQUIDATION_SPOKE), params.debtToCover);
        // EXECUTION_CALLBACK remains set throughout this immutable endpoint call.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        LIQUIDATION_SPOKE.liquidationCall(
            params.collateralReserveId,
            params.debtReserveId,
            params.borrower,
            params.debtToCover,
            false
        );
        DEBT_ASSET.forceApprove(address(LIQUIDATION_SPOKE), 0);

        uint256 debtBalanceAfter = DEBT_ASSET.balanceOf(address(this));
        if (debtBalanceAfter > debtBalanceBefore) revert UnexpectedDebtBalance();
        debtRepaid = debtBalanceBefore - debtBalanceAfter;

        uint256 collateralBalanceAfter = COLLATERAL_ASSET.balanceOf(address(this));
        if (collateralBalanceAfter < collateralBalanceBefore) {
            revert UnexpectedCollateralBalance(collateralBalanceAfter, collateralBalanceBefore);
        }
        collateralReceived = collateralBalanceAfter - collateralBalanceBefore;
        if (collateralReceived < params.minCollateralReceived) {
            revert InsufficientCollateralReceived(collateralReceived, params.minCollateralReceived);
        }
    }

    function _sellCollateral(uint256 collateralReceived, uint256 minDebtAssetOut)
        private
        returns (uint256 debtAssetReceived)
    {
        uint256 collateralBalanceAfterLiquidation = COLLATERAL_ASSET.balanceOf(address(this));
        uint256 collateralBalanceBefore = collateralBalanceAfterLiquidation - collateralReceived;
        uint256 debtBalanceBefore = DEBT_ASSET.balanceOf(address(this));

        COLLATERAL_ASSET.forceApprove(MULTILIQUID_DELEGATE, collateralReceived);
        _swapCollateral(collateralReceived, minDebtAssetOut);
        COLLATERAL_ASSET.forceApprove(MULTILIQUID_DELEGATE, 0);

        uint256 collateralBalanceAfter = COLLATERAL_ASSET.balanceOf(address(this));
        if (collateralBalanceAfter != collateralBalanceBefore) {
            revert UnexpectedCollateralBalance(collateralBalanceAfter, collateralBalanceBefore);
        }

        uint256 debtBalanceAfter = DEBT_ASSET.balanceOf(address(this));
        if (debtBalanceAfter < debtBalanceBefore) revert UnexpectedDebtBalance();

        debtAssetReceived = debtBalanceAfter - debtBalanceBefore;
        if (debtAssetReceived < minDebtAssetOut) {
            revert InsufficientDebtAssetReceived(debtAssetReceived, minDebtAssetOut);
        }
    }

    function _swapCollateral(uint256 collateralAmount, uint256 minDebtAssetOut) private {
        IMultiliquidSwap.SwapInputs[] memory inputs = new IMultiliquidSwap.SwapInputs[](1);
        inputs[0] = IMultiliquidSwap.SwapInputs({
            routeId: RWA_TO_STABLE_EXACT_IN,
            assetInID: COLLATERAL_ASSET_ID,
            assetOutID: DEBT_ASSET_ID,
            stablecoinDelegateID: STABLECOIN_DELEGATE_ID,
            assetInAmt: collateralAmount,
            assetOutAmt: minDebtAssetOut
        });

        // EXECUTION_CALLBACK remains set throughout this immutable endpoint call.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        MULTILIQUID_SWAP.swap(
            address(this),
            address(this),
            inputs,
            IMultiliquidSwap.ApprovalPermit({deadline: 0, signature: ""})
        );
    }
}
