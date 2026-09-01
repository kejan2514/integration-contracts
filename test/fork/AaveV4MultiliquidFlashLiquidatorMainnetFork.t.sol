// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";
import {AaveV4MultiliquidFlashLiquidator} from "src/AaveV4MultiliquidFlashLiquidator.sol";
import {IAaveV3FlashLoanPool} from "src/interfaces/IAaveV3FlashLoanPool.sol";
import {IAaveV4Spoke} from "src/interfaces/IAaveV4Spoke.sol";
import {IMultiliquidSwap} from "src/interfaces/IMultiliquidSwap.sol";

interface IAaveV3PoolView is IAaveV3FlashLoanPool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface IAaveV4SpokeFork is IAaveV4Spoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAmount);

    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 borrowedShares, uint256 borrowedAmount);

    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf)
        external;

    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    function getUserAccountData(address user) external view returns (UserAccountData memory);
}

interface IAaveV4Oracle {
    function getReservePrice(uint256 reserveId) external view returns (uint256);

    function getReserveSource(uint256 reserveId) external view returns (address);
}

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IAccessControlView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IMainnetStablecoinDelegate {
    function balanceSheetCustodyAddress() external view returns (address);

    function stablecoinCustodyAddress() external view returns (address);

    function issuerAdmins(address account) external view returns (bool);

    function rwaWhitelist(address asset) external view returns (bool);

    function whitelistRWA(address asset, bool accepted) external;

    function setRWADiscountRate(bytes32 rwaId, uint256 rate) external;
}

interface IMainnetMultiliquidRegistry is IMultiliquidSwap {
    function paused() external view returns (bool);

    function rwaInfo(bytes32 rwaId)
        external
        view
        returns (
            bool accepted,
            bool additionalRiskControls,
            uint8 decimals,
            address delegate,
            address asset
        );

    function stablecoinInfo(bytes32 stablecoinId)
        external
        view
        returns (bool accepted, bool yieldBearing, uint8 decimals, address delegate, address asset);

    function rwaPriceAdapters(bytes32 rwaId) external view returns (address);

    function discountRates(bytes32 stablecoinId, bytes32 rwaId) external view returns (uint256);

    function setRWAAcceptance(bytes32 rwaId, address delegate, address asset, bool accepted)
        external;

    function setRwaPriceAdapter(bytes32 rwaId, address priceAdapter) external;

    function setRwaWhitelistAdapter(bytes32 rwaId, address whitelistAdapter) external;
}

/// @dev Fork-only adapter that gives Multiliquid the same XAU/USD source used by Aave V4.
contract ForkChainlinkPriceAdapter {
    IChainlinkAggregatorV3 public immutable PRICE_FEED;
    uint256 public immutable DECIMAL_MULTIPLIER;
    uint256 public immutable MAX_AGE;

    error InvalidFeed();
    error InvalidPrice();
    error InvalidRound();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error UnsupportedDecimals();

    constructor(address priceFeed, uint256 maxAge) {
        if (priceFeed == address(0) || maxAge == 0) revert InvalidFeed();

        PRICE_FEED = IChainlinkAggregatorV3(priceFeed);
        MAX_AGE = maxAge;

        uint8 feedDecimals = PRICE_FEED.decimals();
        if (feedDecimals > 18) revert UnsupportedDecimals();
        DECIMAL_MULTIPLIER = 10 ** (18 - feedDecimals);
    }

    function getPrice() external view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            PRICE_FEED.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
            revert InvalidRound();
        }
        if (block.timestamp - updatedAt > MAX_AGE) revert StalePrice(updatedAt, MAX_AGE);

        return uint256(answer) * DECIMAL_MULTIPLIER;
    }
}

/**
 * @notice Mainnet-fork integration for an unfunded solver liquidating real Aave V4 XAUt.
 *
 * The test uses the deployed Aave V4 Gold Spoke for the position and liquidation, the deployed
 * Aave V3 Pool for USDC flash liquidity, and the deployed Multiliquid swap and Uniform USDC
 * delegate for settlement. XAUt is not yet registered on Multiliquid, so the fork test performs
 * that prospective configuration through the deployed contracts' production admin interfaces.
 */
contract AaveV4MultiliquidFlashLiquidatorMainnetForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant PINNED_MAINNET_BLOCK = 25_883_433;
    uint256 private constant PERCENTAGE_FACTOR = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant XAUT_COLLATERAL_RESERVE_ID = 0;
    uint256 private constant USDC_DEBT_RESERVE_ID = 1;
    uint256 private constant XAUT_SUPPLY_AMOUNT = 1e6;
    uint256 private constant LIQUIDATION_REQUEST = 100e6;
    uint256 private constant BORROW_UTILIZATION_NUMERATOR = 99_999;
    uint256 private constant BORROW_UTILIZATION_DENOMINATOR = 100_000;
    uint256 private constant INTEREST_ACCRUAL_STEP = 1 hours;
    uint256 private constant MAX_INTEREST_ACCRUAL_TIME = 12 hours;
    uint256 private constant PRICE_MAX_AGE = 25 hours;
    uint256 private constant XAUT_DISCOUNT_RATE = 25e14; // 25 bps in WAD

    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 private constant XAUT_ID = keccak256("XAUt");
    bytes32 private constant USDC_ID =
        0x58e27f2731863499e6a23a1662ebeed9041d6b40996ea9ca7f4ebc54201823b4;

    address private constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address private constant AAVE_V3_AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address private constant AAVE_V4_GOLD_SPOKE = 0x65407b940966954b23dfA3caA5C0702bB42984DC;
    address private constant AAVE_V4_GOLD_ORACLE = 0x0083421fd178749af2201ddA5A7C3feB5790B80c;
    address private constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address private constant MULTILIQUID_SWAP = 0xD66211cf522Ba23B59789ffF6524c1f03E13E20c;
    address private constant UNIFORM_USDC_DELEGATE = 0x0630582db5a1949509f21B315677C40b9aEb7bDA;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant UTILA_OPERATOR = 0xFb7DB655344C3A4B7866eFE82DBc76DCe813FFc6;
    address private constant UTILA_ISSUER_ADMIN = 0x110a067Bc26A5861dcCC7D7893f8267e602414dB;

    struct PositionState {
        uint256 debtBeforeLiquidation;
        uint256 healthFactorBeforeLiquidation;
        uint256 elapsedTime;
    }

    struct ForkExpectations {
        uint256 debtRepaid;
        uint256 collateralReceived;
        uint256 tokenOut;
        uint256 premium;
        uint256 profit;
    }

    struct ForkBalances {
        uint256 solverUsdc;
        uint256 aUsdcLiquidity;
        uint256 rwaCustodyXaut;
    }

    bool private runForkTests;
    address private solver;
    address private borrower;
    address private rwaCustody;
    address private stablecoinCustody;
    IAaveV4SpokeFork private goldSpoke;
    IMainnetMultiliquidRegistry private multiliquid;
    IMainnetStablecoinDelegate private usdcDelegate;
    ForkChainlinkPriceAdapter private xautPriceAdapter;
    AaveV4MultiliquidFlashLiquidator private liquidator;

    modifier mainnetFork() {
        if (!runForkTests) vm.skip(true, "set RUN_MAINNET_FORK_TESTS=true to run");
        _;
    }

    function setUp() public {
        runForkTests = vm.envOr("RUN_MAINNET_FORK_TESTS", false);
        if (!runForkTests) return;

        string memory rpcUrl = vm.envOr("MAINNET_FORK_RPC_URL", string("http://127.0.0.1:8545"));
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", PINNED_MAINNET_BLOCK);
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        assertEq(block.chainid, 1, "fork must use Ethereum mainnet chain ID");

        solver = makeAddr("solver");
        borrower = makeAddr("borrower");
        goldSpoke = IAaveV4SpokeFork(AAVE_V4_GOLD_SPOKE);
        multiliquid = IMainnetMultiliquidRegistry(MULTILIQUID_SWAP);
        usdcDelegate = IMainnetStablecoinDelegate(UNIFORM_USDC_DELEGATE);

        _assertLiveDeployment();
    }

    function testFork_unfundedSolverLiquidatesRealAaveV4XautAndSettlesOnMultiliquid()
        public
        mainnetFork
    {
        _configureMultiliquidXaut();
        _deployLiquidator();
        PositionState memory position = _createUnhealthyAaveV4Position();
        ForkExpectations memory expected = _preflightAndQuoteLiquidation();
        _seedMultiliquidSettlement(expected);

        ForkBalances memory balances = ForkBalances({
            solverUsdc: IERC20(USDC).balanceOf(solver),
            aUsdcLiquidity: IERC20(USDC).balanceOf(AAVE_V3_AUSDC),
            rwaCustodyXaut: IERC20(XAUT).balanceOf(rwaCustody)
        });

        vm.prank(solver);
        uint256 profit = liquidator.executeLiquidation(_executionParams(expected));

        _assertSettlement(position, expected, balances, profit);
    }

    function _configureMultiliquidXaut() private {
        xautPriceAdapter = new ForkChainlinkPriceAdapter(XAU_USD_FEED, PRICE_MAX_AGE);

        vm.startPrank(UTILA_OPERATOR);
        multiliquid.setRWAAcceptance(XAUT_ID, address(0), XAUT, true);
        multiliquid.setRwaPriceAdapter(XAUT_ID, address(xautPriceAdapter));
        multiliquid.setRwaWhitelistAdapter(XAUT_ID, address(0));
        vm.stopPrank();

        vm.startPrank(UTILA_ISSUER_ADMIN);
        usdcDelegate.whitelistRWA(XAUT, true);
        usdcDelegate.setRWADiscountRate(XAUT_ID, XAUT_DISCOUNT_RATE);
        vm.stopPrank();

        (bool accepted, bool additionalRiskControls, uint8 decimals,, address asset) =
            multiliquid.rwaInfo(XAUT_ID);
        assertTrue(accepted, "XAUt registration");
        assertFalse(additionalRiskControls, "XAUt should not use an RWA delegate");
        assertEq(decimals, 6, "XAUt decimals");
        assertEq(asset, XAUT, "XAUt asset");
        assertEq(multiliquid.rwaPriceAdapters(XAUT_ID), address(xautPriceAdapter), "price adapter");
        assertTrue(usdcDelegate.rwaWhitelist(XAUT), "Uniform USDC XAUt whitelist");
        assertEq(
            multiliquid.discountRates(USDC_ID, XAUT_ID), XAUT_DISCOUNT_RATE, "25 bps XAUt discount"
        );

        uint256 aavePrice =
            IAaveV4Oracle(AAVE_V4_GOLD_ORACLE).getReservePrice(XAUT_COLLATERAL_RESERVE_ID);
        assertEq(xautPriceAdapter.getPrice(), aavePrice * 1e10, "shared XAU/USD price");
    }

    function _deployLiquidator() private {
        liquidator = new AaveV4MultiliquidFlashLiquidator(
            solver,
            IAaveV3FlashLoanPool(AAVE_V3_POOL),
            IAaveV4Spoke(AAVE_V4_GOLD_SPOKE),
            IMultiliquidSwap(MULTILIQUID_SWAP),
            IERC20(XAUT),
            IERC20(USDC),
            UNIFORM_USDC_DELEGATE,
            XAUT_ID,
            USDC_ID,
            USDC_ID
        );

        rwaCustody = usdcDelegate.balanceSheetCustodyAddress();
        stablecoinCustody = usdcDelegate.stablecoinCustodyAddress();
        assertTrue(rwaCustody != address(0), "RWA custody");
        assertTrue(stablecoinCustody != address(0), "stablecoin custody");
    }

    function _createUnhealthyAaveV4Position() private returns (PositionState memory position) {
        deal(XAUT, borrower, XAUT_SUPPLY_AMOUNT, true);

        vm.startPrank(borrower);
        IERC20(XAUT).forceApprove(AAVE_V4_GOLD_SPOKE, XAUT_SUPPLY_AMOUNT);
        goldSpoke.supply(XAUT_COLLATERAL_RESERVE_ID, XAUT_SUPPLY_AMOUNT, borrower);
        goldSpoke.setUsingAsCollateral(XAUT_COLLATERAL_RESERVE_ID, true, borrower);

        IAaveV4SpokeFork.UserAccountData memory collateralAccount =
            goldSpoke.getUserAccountData(borrower);
        uint256 maxDebtValue =
            collateralAccount.totalCollateralValue * collateralAccount.avgCollateralFactor / WAD;
        uint256 usdcPrice = IAaveV4Oracle(AAVE_V4_GOLD_ORACLE).getReservePrice(USDC_DEBT_RESERVE_ID);
        // Aave V4 Value amounts carry an additional WAD scale on top of the 8-decimal oracle
        // price. Remove that scale when converting the maximum debt value into USDC units.
        uint256 maxBorrowAmount = maxDebtValue * 1e6 / usdcPrice / WAD;
        uint256 borrowAmount =
            maxBorrowAmount * BORROW_UTILIZATION_NUMERATOR / BORROW_UTILIZATION_DENOMINATOR;
        goldSpoke.borrow(USDC_DEBT_RESERVE_ID, borrowAmount, borrower);
        vm.stopPrank();

        IAaveV4SpokeFork.UserAccountData memory account = goldSpoke.getUserAccountData(borrower);
        assertGe(account.healthFactor, WAD, "position must begin healthy");
        assertEq(account.activeCollateralCount, 1, "active XAUt collateral");
        assertEq(account.borrowCount, 1, "active USDC debt");

        while (account.healthFactor >= WAD && position.elapsedTime < MAX_INTEREST_ACCRUAL_TIME) {
            vm.warp(block.timestamp + INTEREST_ACCRUAL_STEP);
            position.elapsedTime += INTEREST_ACCRUAL_STEP;
            account = goldSpoke.getUserAccountData(borrower);
        }

        assertLt(account.healthFactor, WAD, "USDC interest must make the position liquidatable");
        position.healthFactorBeforeLiquidation = account.healthFactor;
        position.debtBeforeLiquidation = goldSpoke.getUserTotalDebt(USDC_DEBT_RESERVE_ID, borrower);
    }

    function _preflightAndQuoteLiquidation() private returns (ForkExpectations memory expected) {
        uint256 snapshot = vm.snapshotState();

        deal(USDC, address(this), LIQUIDATION_REQUEST, true);
        IERC20(USDC).forceApprove(AAVE_V4_GOLD_SPOKE, LIQUIDATION_REQUEST);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 xautBefore = IERC20(XAUT).balanceOf(address(this));

        goldSpoke.liquidationCall(
            XAUT_COLLATERAL_RESERVE_ID, USDC_DEBT_RESERVE_ID, borrower, LIQUIDATION_REQUEST, false
        );

        expected.debtRepaid = usdcBefore - IERC20(USDC).balanceOf(address(this));
        expected.collateralReceived = IERC20(XAUT).balanceOf(address(this)) - xautBefore;
        assertGt(expected.debtRepaid, 0, "real Aave V4 debt repaid");
        assertGt(expected.collateralReceived, 0, "real Aave V4 XAUt received");
        assertTrue(vm.revertToState(snapshot), "preflight snapshot restore");

        IMultiliquidSwap.SwapInputs memory swapInput = IMultiliquidSwap.SwapInputs({
            routeId: 2,
            assetInID: XAUT_ID,
            assetOutID: USDC_ID,
            stablecoinDelegateID: USDC_ID,
            assetInAmt: expected.collateralReceived,
            assetOutAmt: 0
        });
        IMultiliquidSwap.SwapResolved memory quote =
            multiliquid.quoteSwap(address(liquidator), swapInput);

        expected.premium = LIQUIDATION_REQUEST
            * IAaveV3PoolView(AAVE_V3_POOL).FLASHLOAN_PREMIUM_TOTAL() / PERCENTAGE_FACTOR;
        assertGt(
            quote.tokenOutAmt,
            expected.debtRepaid + expected.premium,
            "liquidation must cover restored debt and flash premium"
        );
        expected.tokenOut = quote.tokenOutAmt;
        expected.profit = quote.tokenOutAmt - expected.debtRepaid - expected.premium;
    }

    function _seedMultiliquidSettlement(ForkExpectations memory expected) private {
        IMultiliquidSwap.SwapInputs memory swapInput = IMultiliquidSwap.SwapInputs({
            routeId: 2,
            assetInID: XAUT_ID,
            assetOutID: USDC_ID,
            stablecoinDelegateID: USDC_ID,
            assetInAmt: expected.collateralReceived,
            assetOutAmt: 0
        });
        IMultiliquidSwap.SwapResolved memory quote =
            multiliquid.quoteSwap(address(liquidator), swapInput);

        _addTokenBalance(
            USDC,
            stablecoinCustody,
            quote.tokenOutAmt + quote.issuerFeeAmt + quote.spreadFeeAmt + quote.lpFeeAmt
        );
        vm.prank(stablecoinCustody);
        assertTrue(
            IERC20(USDC).approve(UNIFORM_USDC_DELEGATE, type(uint256).max), "custody USDC approval"
        );
    }

    function _executionParams(ForkExpectations memory expected)
        private
        view
        returns (AaveV4MultiliquidFlashLiquidator.ExecutionParams memory)
    {
        return AaveV4MultiliquidFlashLiquidator.ExecutionParams({
            collateralReserveId: XAUT_COLLATERAL_RESERVE_ID,
            debtReserveId: USDC_DEBT_RESERVE_ID,
            borrower: borrower,
            debtToCover: LIQUIDATION_REQUEST,
            flashLoanAmount: LIQUIDATION_REQUEST,
            minCollateralReceived: expected.collateralReceived,
            minDebtAssetOut: expected.tokenOut,
            minProfit: expected.profit,
            referralCode: 0
        });
    }

    function _assertSettlement(
        PositionState memory position,
        ForkExpectations memory expected,
        ForkBalances memory balances,
        uint256 profit
    ) private view {
        assertGt(position.elapsedTime, 0, "position became unhealthy through debt interest");
        assertLt(position.healthFactorBeforeLiquidation, WAD, "pre-liquidation health factor");
        assertEq(profit, expected.profit, "reported profit");
        assertEq(
            IERC20(USDC).balanceOf(solver) - balances.solverUsdc, expected.profit, "solver profit"
        );
        assertEq(
            IERC20(USDC).balanceOf(AAVE_V3_AUSDC) - balances.aUsdcLiquidity,
            expected.premium,
            "Aave V3 flash premium"
        );
        uint256 debtReduction = position.debtBeforeLiquidation
            - goldSpoke.getUserTotalDebt(USDC_DEBT_RESERVE_ID, borrower);
        // The Spoke pulls the exact underlying amount, while getUserTotalDebt converts the
        // remaining debt shares back to assets and can round that view down by one USDC unit.
        assertApproxEqAbs(debtReduction, expected.debtRepaid, 1, "real Aave V4 debt reduction");
        assertEq(
            IERC20(XAUT).balanceOf(rwaCustody) - balances.rwaCustodyXaut,
            expected.collateralReceived,
            "Multiliquid custody receives liquidated XAUt"
        );
        assertEq(IERC20(USDC).balanceOf(address(liquidator)), 0, "no USDC remains");
        assertEq(IERC20(XAUT).balanceOf(address(liquidator)), 0, "no XAUt remains");
    }

    function _assertLiveDeployment() private view {
        assertGt(AAVE_V3_POOL.code.length, 0, "Aave V3 Pool code");
        assertGt(AAVE_V3_AUSDC.code.length, 0, "Aave V3 aUSDC code");
        assertGt(AAVE_V4_GOLD_SPOKE.code.length, 0, "Aave V4 Gold Spoke code");
        assertGt(AAVE_V4_GOLD_ORACLE.code.length, 0, "Aave V4 Gold oracle code");
        assertGt(XAU_USD_FEED.code.length, 0, "XAU/USD feed code");
        assertGt(MULTILIQUID_SWAP.code.length, 0, "MultiliquidSwap code");
        assertGt(UNIFORM_USDC_DELEGATE.code.length, 0, "Uniform USDC delegate code");
        assertGt(XAUT.code.length, 0, "XAUt code");
        assertGt(USDC.code.length, 0, "USDC code");

        assertFalse(multiliquid.paused(), "Multiliquid is paused");
        assertTrue(
            IAccessControlView(MULTILIQUID_SWAP).hasRole(OPERATOR_ROLE, UTILA_OPERATOR),
            "UTILA operator role"
        );
        assertTrue(usdcDelegate.issuerAdmins(UTILA_ISSUER_ADMIN), "UTILA issuer admin");

        IAaveV4SpokeFork.Reserve memory xautReserve =
            goldSpoke.getReserve(XAUT_COLLATERAL_RESERVE_ID);
        IAaveV4SpokeFork.Reserve memory usdcReserve = goldSpoke.getReserve(USDC_DEBT_RESERVE_ID);
        assertEq(xautReserve.underlying, XAUT, "Gold Spoke XAUt reserve");
        assertEq(xautReserve.decimals, 6, "Gold Spoke XAUt decimals");
        assertEq(usdcReserve.underlying, USDC, "Gold Spoke USDC reserve");
        assertEq(usdcReserve.decimals, 6, "Gold Spoke USDC decimals");
        assertEq(
            IAaveV4Oracle(AAVE_V4_GOLD_ORACLE).getReserveSource(XAUT_COLLATERAL_RESERVE_ID),
            XAU_USD_FEED,
            "Aave V4 XAUt oracle source"
        );
        assertEq(IChainlinkAggregatorV3(XAU_USD_FEED).decimals(), 8, "XAU/USD decimals");
        assertEq(IChainlinkAggregatorV3(XAU_USD_FEED).description(), "XAU / USD");

        (bool stableAccepted,,, address delegate, address stableAsset) =
            multiliquid.stablecoinInfo(USDC_ID);
        assertTrue(stableAccepted, "USDC is not registered");
        assertEq(delegate, UNIFORM_USDC_DELEGATE, "USDC delegate registration");
        assertEq(stableAsset, USDC, "USDC registration");
    }

    function _addTokenBalance(address token, address account, uint256 amount) private {
        uint256 currentBalance = IERC20(token).balanceOf(account);
        deal(token, account, currentBalance + amount, true);
    }
}
