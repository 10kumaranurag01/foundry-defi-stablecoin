// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("USER");
    address public USER2 = makeAddr("USER2");
    address public liquidator = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 20 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 5 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_BURN = 5 ether;
    uint256 public constant STARTING_USER_BALANCE = 20 ether;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    uint256 public collateralToCover = 20 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        if (block.chainid == 31_337) {
            vm.deal(USER, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DCSEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * $2000 per ETH = 30,000e18 -> Calculated in wei
        uint256 expectedUsd = 30000e18;
        uint256 actaulUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actaulUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSITCOLLATERAL TEST
    //////////////////////////////////////////////////////////////*/

    function testZeroIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DCSEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, STARTING_USER_BALANCE);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DCSEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInfo(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /*//////////////////////////////////////////////////////////////
                  DEPOSIT COLLATERAL AND MINT DSC TEST
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateralAndMintDSC(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndMintDSC() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInfo(USER);
        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralAndMintDSCFailsIfHealthFactorBroken() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        // We are doing the below line to know the USD value of the DSC to be minted
        // Because its USD value is required to calculate the health factor
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DCSEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);

        vm.stopPrank();
    }

    function testDepositCollateralAndEmitEvent() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(USER, address(weth), AMOUNT_COLLATERAL);

        dsce.depositCollateral(address(weth), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testMintDSCFailsWithoutCollateral() public {
        vm.startPrank(USER);

        uint256 expectedHealthFactor = 0;

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DCSEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDSC(AMOUNT_DSC_TO_MINT);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         REDEEM COLLATERAL TEST
    //////////////////////////////////////////////////////////////*/

    function testRedeemCollateral() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateralAndMintDSC(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);

        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL_TO_REDEEM);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInfo(USER);
        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT;
        uint256 actualDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        uint256 expectedDepositAmount = AMOUNT_COLLATERAL - AMOUNT_COLLATERAL_TO_REDEEM;

        assertEq(totalDscMinted, expectedTotalDscMinted); // working
        assertEq(actualDepositAmount, expectedDepositAmount);

        vm.stopPrank();
    }

    function testredeemCollateralForDSC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);

        dsc.approve(address(dsce), AMOUNT_COLLATERAL_TO_REDEEM);
        dsce.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_BURN);

        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_DSC_TO_MINT - AMOUNT_DSC_TO_BURN);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION TEST
    //////////////////////////////////////////////////////////////*/

    function testRevertIfHealthFactorOfTheUserIsOk() public depositedCollateral {
        vm.startPrank(USER2);
        vm.expectRevert(DSCEngine.DCSEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMustImproveHealthFactorOnLiquidation() public {
        uint256 amountToMint = 100 ether;

        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDSC(address(weth), AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);

        // Act
        int256 ethUsdUpdatedPrice = 9e8; // 1 ETH = $9
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Act / Assert
        vm.expectRevert(DSCEngine.DCSEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }
}
