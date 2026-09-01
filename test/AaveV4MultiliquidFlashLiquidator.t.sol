// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";
import {AaveV4MultiliquidFlashLiquidator} from "src/AaveV4MultiliquidFlashLiquidator.sol";
import {IAaveV3FlashLoanPool} from "src/interfaces/IAaveV3FlashLoanPool.sol";
import {IAaveV3FlashLoanSimpleReceiver} from "src/interfaces/IAaveV3FlashLoanSimpleReceiver.sol";
import {IAaveV4Spoke} from "src/interfaces/IAaveV4Spoke.sol";
import {IMultiliquidSwap} from "src/interfaces/IMultiliquidSwap.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AaveV4MultiliquidFlashLiquidatorTest is Test {
    uint256 private constant COLLATERAL_RESERVE_ID = 4;
    uint256 private constant DEBT_RESERVE_ID = 9;
    uint256 private constant FLASH_AMOUNT = 100e18;
    uint256 private constant FLASH_PREMIUM = 1e18;
    uint256 private constant COLLATERAL_RECEIVED = 110e18;
    uint256 private constant SWAP_OUTPUT = 106e18;
    uint256 private constant EXPECTED_PROFIT = 5e18;

    bytes32 private constant COLLATERAL_ASSET_ID = keccak256("RWA");
    bytes32 private constant DEBT_ASSET_ID = keccak256("USDC");
    bytes32 private constant STABLECOIN_DELEGATE_ID = keccak256("USDC_DELEGATE");

    address private solver;
    address private borrower;
    address private stranger;

    MockERC20 private collateralAsset;
    MockERC20 private debtAsset;
    MockAaveV3FlashLoanPool private flashLoanPool;
    MockAaveV4Spoke private liquidationSpoke;
    MockMultiliquidDelegate private multiliquidDelegate;
    MockMultiliquidSwap private multiliquidSwap;
    AaveV4MultiliquidFlashLiquidator private liquidator;

    function setUp() public {
        solver = makeAddr("solver");
        borrower = makeAddr("borrower");
        stranger = makeAddr("stranger");

        collateralAsset = new MockERC20("RWA Collateral", "RWA");
        debtAsset = new MockERC20("Debt Asset", "DEBT");

        flashLoanPool = new MockAaveV3FlashLoanPool(debtAsset, FLASH_PREMIUM);
        liquidationSpoke = new MockAaveV4Spoke(collateralAsset, debtAsset);
        multiliquidDelegate = new MockMultiliquidDelegate(collateralAsset, debtAsset);
        multiliquidSwap = new MockMultiliquidSwap(
            multiliquidDelegate, COLLATERAL_ASSET_ID, DEBT_ASSET_ID, STABLECOIN_DELEGATE_ID
        );
        multiliquidDelegate.setMultiliquidSwap(address(multiliquidSwap));

        liquidator = new AaveV4MultiliquidFlashLiquidator(
            solver,
            flashLoanPool,
            liquidationSpoke,
            IMultiliquidSwap(address(multiliquidSwap)),
            collateralAsset,
            debtAsset,
            address(multiliquidDelegate),
            COLLATERAL_ASSET_ID,
            DEBT_ASSET_ID,
            STABLECOIN_DELEGATE_ID
        );

        debtAsset.mint(address(flashLoanPool), 1_000e18);
        collateralAsset.mint(address(liquidationSpoke), 1_000e18);
        debtAsset.mint(address(multiliquidDelegate), 1_000e18);

        liquidationSpoke.configure(FLASH_AMOUNT, COLLATERAL_RECEIVED);
        multiliquidSwap.setSwapOutput(SWAP_OUTPUT);
    }

    function test_executeLiquidation_flashFinancesFullFlowAndPaysProfit() public {
        uint256 flashPoolBalanceBefore = debtAsset.balanceOf(address(flashLoanPool));

        vm.prank(solver);
        uint256 profit = liquidator.executeLiquidation(_defaultParams());

        assertEq(profit, EXPECTED_PROFIT, "reported profit");
        assertEq(debtAsset.balanceOf(solver), EXPECTED_PROFIT, "solver receives profit");
        assertEq(debtAsset.balanceOf(address(liquidator)), 0, "no debt asset remains");
        assertEq(collateralAsset.balanceOf(address(liquidator)), 0, "no collateral remains");
        assertEq(
            debtAsset.balanceOf(address(flashLoanPool)),
            flashPoolBalanceBefore + FLASH_PREMIUM,
            "flash pool receives principal and premium"
        );
        assertEq(debtAsset.balanceOf(address(liquidationSpoke)), FLASH_AMOUNT, "V4 debt restored");
        assertEq(
            collateralAsset.balanceOf(address(multiliquidDelegate)),
            COLLATERAL_RECEIVED,
            "Multiliquid delegate receives collateral"
        );

        assertEq(liquidationSpoke.lastCollateralReserveId(), COLLATERAL_RESERVE_ID);
        assertEq(liquidationSpoke.lastDebtReserveId(), DEBT_RESERVE_ID);
        assertEq(liquidationSpoke.lastBorrower(), borrower);
        assertFalse(liquidationSpoke.lastReceiveShares(), "underlying collateral requested");

        assertEq(
            debtAsset.allowance(address(liquidator), address(flashLoanPool)),
            0,
            "flash approval cleared"
        );
        assertEq(
            debtAsset.allowance(address(liquidator), address(liquidationSpoke)),
            0,
            "Spoke approval cleared"
        );
        assertEq(
            collateralAsset.allowance(address(liquidator), address(multiliquidDelegate)),
            0,
            "Multiliquid approval cleared"
        );
    }

    function test_executeLiquidation_preservesPreexistingDebtAssetBalance() public {
        uint256 preexistingBalance = 10e18;
        debtAsset.mint(address(liquidator), preexistingBalance);

        vm.prank(solver);
        uint256 profit = liquidator.executeLiquidation(_defaultParams());

        assertEq(profit, EXPECTED_PROFIT);
        assertEq(debtAsset.balanceOf(solver), EXPECTED_PROFIT);
        assertEq(
            debtAsset.balanceOf(address(liquidator)),
            preexistingBalance,
            "existing solver capital is not consumed or reported as profit"
        );
    }

    function test_executeLiquidation_sellsOnlyNewlyReceivedCollateral() public {
        uint256 preexistingCollateral = 7e18;
        collateralAsset.mint(address(liquidator), preexistingCollateral);

        vm.prank(solver);
        liquidator.executeLiquidation(_defaultParams());

        assertEq(
            collateralAsset.balanceOf(address(liquidator)),
            preexistingCollateral,
            "existing collateral is not sold"
        );
        assertEq(
            collateralAsset.balanceOf(address(multiliquidDelegate)),
            COLLATERAL_RECEIVED,
            "only liquidation proceeds are sold"
        );
    }

    function test_executeLiquidation_revertsWhenSwapCannotFundRepayment() public {
        multiliquidSwap.setSwapOutput(FLASH_AMOUNT);
        AaveV4MultiliquidFlashLiquidator.ExecutionParams memory params = _defaultParams();
        params.minDebtAssetOut = FLASH_AMOUNT;
        params.minProfit = 0;

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4MultiliquidFlashLiquidator.InsufficientRepaymentBalance.selector,
                FLASH_AMOUNT,
                FLASH_AMOUNT + FLASH_PREMIUM
            )
        );
        liquidator.executeLiquidation(params);

        assertEq(debtAsset.balanceOf(address(flashLoanPool)), 1_000e18, "loan rolled back");
        assertEq(debtAsset.balanceOf(address(liquidationSpoke)), 0, "liquidation rolled back");
        assertEq(collateralAsset.balanceOf(address(multiliquidDelegate)), 0, "swap rolled back");
    }

    function test_executeLiquidation_revertsWhenMinimumProfitIsNotMet() public {
        AaveV4MultiliquidFlashLiquidator.ExecutionParams memory params = _defaultParams();
        params.minProfit = EXPECTED_PROFIT + 1;

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4MultiliquidFlashLiquidator.InsufficientProfit.selector,
                EXPECTED_PROFIT,
                EXPECTED_PROFIT + 1
            )
        );
        liquidator.executeLiquidation(params);
    }

    function test_executeLiquidation_revertsWhenCollateralReceivedIsBelowMinimum() public {
        AaveV4MultiliquidFlashLiquidator.ExecutionParams memory params = _defaultParams();
        params.minCollateralReceived = COLLATERAL_RECEIVED + 1;

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4MultiliquidFlashLiquidator.InsufficientCollateralReceived.selector,
                COLLATERAL_RECEIVED,
                COLLATERAL_RECEIVED + 1
            )
        );
        liquidator.executeLiquidation(params);
    }

    function test_executeLiquidation_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        liquidator.executeLiquidation(_defaultParams());
    }

    function test_executeLiquidation_revertsWhenDebtToCoverExceedsFlashAmount() public {
        AaveV4MultiliquidFlashLiquidator.ExecutionParams memory params = _defaultParams();
        params.debtToCover = params.flashLoanAmount + 1;

        vm.prank(solver);
        vm.expectRevert(AaveV4MultiliquidFlashLiquidator.InvalidExecutionAmount.selector);
        liquidator.executeLiquidation(params);
    }

    function test_executeOperation_rejectsUnsolicitedCallback() public {
        vm.prank(address(flashLoanPool));
        vm.expectRevert(AaveV4MultiliquidFlashLiquidator.InvalidFlashLoanCallback.selector);
        liquidator.executeOperation(
            address(debtAsset), FLASH_AMOUNT, FLASH_PREMIUM, address(liquidator), ""
        );
    }

    function _defaultParams()
        private
        view
        returns (AaveV4MultiliquidFlashLiquidator.ExecutionParams memory)
    {
        return AaveV4MultiliquidFlashLiquidator.ExecutionParams({
            collateralReserveId: COLLATERAL_RESERVE_ID,
            debtReserveId: DEBT_RESERVE_ID,
            borrower: borrower,
            debtToCover: FLASH_AMOUNT,
            flashLoanAmount: FLASH_AMOUNT,
            minCollateralReceived: COLLATERAL_RECEIVED,
            minDebtAssetOut: SWAP_OUTPUT,
            minProfit: EXPECTED_PROFIT,
            referralCode: 0
        });
    }
}

contract MockAaveV3FlashLoanPool is IAaveV3FlashLoanPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable DEBT_ASSET;
    uint256 public immutable PREMIUM;

    error InvalidFlashAsset();
    error InvalidReceiverReturn();
    error FlashLoanNotRepaid();

    constructor(IERC20 debtAsset, uint256 premium) {
        DEBT_ASSET = debtAsset;
        PREMIUM = premium;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        if (asset != address(DEBT_ASSET)) revert InvalidFlashAsset();

        uint256 balanceBefore = DEBT_ASSET.balanceOf(address(this));
        DEBT_ASSET.safeTransfer(receiverAddress, amount);

        bool success = IAaveV3FlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, PREMIUM, msg.sender, params);
        if (!success) revert InvalidReceiverReturn();

        DEBT_ASSET.safeTransferFrom(receiverAddress, address(this), amount + PREMIUM);
        if (DEBT_ASSET.balanceOf(address(this)) != balanceBefore + PREMIUM) {
            revert FlashLoanNotRepaid();
        }
    }
}

contract MockAaveV4Spoke is IAaveV4Spoke {
    using SafeERC20 for IERC20;

    IERC20 public immutable COLLATERAL_ASSET;
    IERC20 public immutable DEBT_ASSET;

    uint256 public debtToRestore;
    uint256 public collateralToLiquidator;

    uint256 public lastCollateralReserveId;
    uint256 public lastDebtReserveId;
    address public lastBorrower;
    bool public lastReceiveShares;

    error InsufficientDebtToCover();
    error ReceiveSharesNotSupported();

    constructor(IERC20 collateralAsset, IERC20 debtAsset) {
        COLLATERAL_ASSET = collateralAsset;
        DEBT_ASSET = debtAsset;
    }

    function configure(uint256 debtToRestore_, uint256 collateralToLiquidator_) external {
        debtToRestore = debtToRestore_;
        collateralToLiquidator = collateralToLiquidator_;
    }

    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool receiveShares
    ) external {
        if (receiveShares) revert ReceiveSharesNotSupported();
        if (debtToCover < debtToRestore) revert InsufficientDebtToCover();

        lastCollateralReserveId = collateralReserveId;
        lastDebtReserveId = debtReserveId;
        lastBorrower = user;
        lastReceiveShares = receiveShares;

        // Match Aave V4's implementation order. Any later failure rolls this transfer back.
        COLLATERAL_ASSET.safeTransfer(msg.sender, collateralToLiquidator);
        DEBT_ASSET.safeTransferFrom(msg.sender, address(this), debtToRestore);
    }
}

contract MockMultiliquidDelegate {
    using SafeERC20 for IERC20;

    IERC20 public immutable COLLATERAL_ASSET;
    IERC20 public immutable DEBT_ASSET;
    address public multiliquidSwap;

    error InvalidCaller();
    error AlreadyConfigured();

    constructor(IERC20 collateralAsset, IERC20 debtAsset) {
        COLLATERAL_ASSET = collateralAsset;
        DEBT_ASSET = debtAsset;
    }

    function setMultiliquidSwap(address multiliquidSwap_) external {
        if (multiliquidSwap != address(0)) revert AlreadyConfigured();
        multiliquidSwap = multiliquidSwap_;
    }

    function settle(address user, address receiver, uint256 collateralAmount, uint256 debtAmount)
        external
    {
        if (msg.sender != multiliquidSwap) revert InvalidCaller();

        COLLATERAL_ASSET.safeTransferFrom(user, address(this), collateralAmount);
        DEBT_ASSET.safeTransfer(receiver, debtAmount);
    }
}

contract MockMultiliquidSwap {
    uint256 private constant RWA_TO_STABLE_EXACT_IN = 2;

    MockMultiliquidDelegate public immutable DELEGATE;
    bytes32 public immutable COLLATERAL_ASSET_ID;
    bytes32 public immutable DEBT_ASSET_ID;
    bytes32 public immutable STABLECOIN_DELEGATE_ID;

    uint256 public swapOutput;

    error InvalidSwap();
    error InsufficientOutput();

    constructor(
        MockMultiliquidDelegate delegate,
        bytes32 collateralAssetId,
        bytes32 debtAssetId,
        bytes32 stablecoinDelegateId
    ) {
        DELEGATE = delegate;
        COLLATERAL_ASSET_ID = collateralAssetId;
        DEBT_ASSET_ID = debtAssetId;
        STABLECOIN_DELEGATE_ID = stablecoinDelegateId;
    }

    function setSwapOutput(uint256 swapOutput_) external {
        swapOutput = swapOutput_;
    }

    function swap(
        address user,
        address receiver,
        IMultiliquidSwap.SwapInputs[] calldata inputs,
        IMultiliquidSwap.ApprovalPermit calldata permit
    ) external {
        if (
            user != msg.sender || receiver != msg.sender || inputs.length != 1
                || permit.signature.length != 0
        ) {
            revert InvalidSwap();
        }

        IMultiliquidSwap.SwapInputs calldata input = inputs[0];
        if (
            input.routeId != RWA_TO_STABLE_EXACT_IN || input.assetInID != COLLATERAL_ASSET_ID
                || input.assetOutID != DEBT_ASSET_ID
                || input.stablecoinDelegateID != STABLECOIN_DELEGATE_ID
        ) {
            revert InvalidSwap();
        }
        if (swapOutput < input.assetOutAmt) revert InsufficientOutput();

        DELEGATE.settle(user, receiver, input.assetInAmt, swapOutput);
    }
}
