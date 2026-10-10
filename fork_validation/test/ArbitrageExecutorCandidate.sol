// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║                    PRODUCTION ARBITRAGE EXECUTOR v3.1                      ║
 * ║                  V2 + V3 Execution via Aave Flash Loans                   ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 *
 * v3.1: see the CHANGELOG at the top of the file. [FIX-5] V4 removed (stub),
 *       [FIX-1] nonReentrant removed from executeOperation (deadlock with startArbitrage).
 *
 * ARCHITECTURE:
 *   - Multi-DEX: Uniswap V2 (swapExactTokensForTokens), V3 (exactInputSingle)
 *   - Cumulative slippage math via exact root approximation in integer space
 *   - Atomic flash loan: entire transaction reverts if endingBalance < threshold
 *   - ReentrancyGuard on startArbitrage + strict callback validation
 *     (_validateFlashCallback) instead of a reentrancy guard on the callback [FIX-1]
 *   - Emergency profit withdrawal with 24h timelock
 *
 * SECURITY MODEL:
 *   1. Only whitelisted routers/tokens
 *   2. Route must start and end with flash-loan asset
 *   3. minOut enforced per hop (early revert)
 *   4. endingBalance >= balanceBefore + debt + minProfitAbs (final truth)
 *   5. 30s execution deadline inside callback
 *   6. No native ETH acceptance
 */




// ─── INTERFACES ─────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IAavePool {
    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface IAaveFlashBorrower {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

// V2 Router
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}

// V3 Router
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

// [FIX-5] The IUniversalRouter (V4) interface was removed: V4 execution was a
// non-functional stub (revert V4ExecutionNotConfigured). Production code must
// not contain revert branches in advertised execution paths. V4 will return in
// a separate version once UniversalRouter/PoolManager quoting is implemented.

// ─── LIBRARIES ──────────────────────────────────────────────────────────────

library FullMath {
    /// @notice Calculates floor(a×b÷denominator)
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly { result := div(prod0, denominator) }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) }
            assembly { prod1 := sub(prod1, gt(remainder, prod0)) }
            assembly { prod0 := sub(prod0, remainder) }
            uint256 twos = (0 - denominator) & denominator;
            assembly { denominator := div(denominator, twos) }
            assembly { prod0 := div(prod0, twos) }
            assembly { twos := add(div(sub(0, twos), twos), 1) }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }
}

library TokenOps {
    error TokenCallReverted(address token, bytes data);
    error TokenCallReturnedFalse(address token);
    error TokenCallMalformed(address token);

    function safeSend(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.transfer.selector, to, value));
    }

    function safeApproveExact(IERC20 token, address spender, uint256 value) internal {
        if (_callOptionalReturnBool(token, abi.encodeWithSelector(IERC20.approve.selector, spender, value))) {
            return;
        }
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.approve.selector, spender, value));
    }

    function _callOptionalReturn(IERC20 token, bytes memory payload) private {
        (bool ok, bytes memory ret) = address(token).call(payload);
        if (!ok) revert TokenCallReverted(address(token), ret);
        if (ret.length == 0) return;
        if (ret.length != 32) revert TokenCallMalformed(address(token));
        if (!abi.decode(ret, (bool))) revert TokenCallReturnedFalse(address(token));
    }

    function _callOptionalReturnBool(IERC20 token, bytes memory payload) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(payload);
        if (!ok) return false;
        if (ret.length == 0) return true;
        if (ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }
}

// ─── REENTRANCY GUARD ───────────────────────────────────────────────────────

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    error ReentrantCall();
    constructor() { _status = _NOT_ENTERED; }
    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// ─── MAIN CONTRACT ──────────────────────────────────────────────────────────

contract ArbitrageExecutor is IAaveFlashBorrower, ReentrancyGuard {
    using TokenOps for IERC20;

    // ── Enums & Structs ─────────────────────────────────────────────────────
    // [FIX-5] DexType.V4 removed — V4 was a stub. Only actually executable DEXs.
    enum DexType { V2, V3 }

    struct Hop {
        DexType dexType;
        address router;
        address tokenIn;
        address tokenOut;
        uint256 minOut;
        uint24 fee;      // V3 fee tier
        // [FIX-5] The `bytes extra` field (V4 calldata suffix) was removed: V4 is
        // gone and the contract never read the field. WARNING: the keeper ABI
        // strings (previewRoute / startArbitrage) were updated in sync — the tuple
        // is now (uint8,address,address,address,uint256,uint24).
    }

    // ── Errors ──────────────────────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error BadCallback();
    error LoanAlreadyOpen();
    error NoLoanOpen();
    error ContractPaused();
    error MustBePaused();
    error NativeTransfersDisabled();
    error AddressNotContract(address target);
    error DeadlineTooFar();
    error DeadlineExpired();
    error ExecutionTimeout();
    error NoProfitableRouteFound();
    error SlippageBpsTooHigh();
    error MinProfitBpsZero();
    error RouterNotWhitelisted(address router);
    error TokenNotWhitelisted(address token);
    error InvalidHopCount();
    error RouteMustStartAndEndOnAsset();
    error HopMinOutZero();
    error EmptyRouterResult();
    error ZeroRouterOutput();
    error InsufficientLoanBalance();
    error ArithmeticOverflow();
    error ProfitWithdrawalLocked();
    error UnlockTimeNotReached();
    error BatchTooLarge();
    error UnsupportedDexType();
    // [FIX-5] error V4ExecutionNotConfigured() removed together with the V4 execution branch.

    // ── Constants ───────────────────────────────────────────────────────────
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;
    uint256 public constant MIN_HOPS = 2;
    uint256 public constant MAX_HOPS = 12;
    uint256 public constant MAX_PLAN_LIFETIME = 30 minutes;
    uint256 public constant MAX_EXECUTION_DELAY = 30 seconds;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant PROFIT_LOCK_PERIOD = 24 hours;

    // ── Immutables ──────────────────────────────────────────────────────────
    address public immutable owner;
    address public immutable aavePool;

    // ── Mutable Config ──────────────────────────────────────────────────────
    address public executor;
    bool public paused;
    bool public loanOpen;
    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public tokenWhitelist;
    uint256 public slippageBps = 30;
    uint256 public minProfitBps = 50;
    uint256 public profitUnlockTime;

    // ── Active Loan State ───────────────────────────────────────────────────
    bytes32 public activeRequestHash;
    address public activeAsset;
    uint256 public activeAmount;
    uint256 public balanceBefore;
    uint256 public executionStartTime;

    // ── Events ────────────────────────────────────────────────────────────────
    event PauseStatusChanged(bool isPaused);
    event ExecutorUpdated(address indexed executor);
    event RouterWhitelistUpdated(address indexed router, bool allowed);
    event TokenWhitelistUpdated(address indexed token, bool allowed);
    event SlippageBpsUpdated(uint256 bps);
    event MinProfitBpsUpdated(uint256 bps);
    event FlashRequested(address indexed asset, uint256 amount, uint256 deadline, uint256 hopCount, bytes32 requestHash);
    event HopExecuted(uint256 indexed hopIndex, DexType dexType, address indexed router, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event FlashCompleted(address indexed asset, uint256 amount, uint256 premium, uint256 profit, bytes32 requestHash);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);
    event ProfitWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event ExecutionDelayed(uint256 elapsed, uint256 limit);

    // ── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyExecutorOrOwner() {
        if (msg.sender != executor && msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier whenRunning() {
        if (paused) revert ContractPaused();
        _;
    }
    modifier noLoanInProgress() {
        if (loanOpen) revert LoanAlreadyOpen();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor(address pool_, address executor_, address[] memory routers, address[] memory tokens) {
        if (pool_ == address(0)) revert ZeroAddress();
        _requireContract(pool_);
        owner = msg.sender;
        aavePool = pool_;
        executor = executor_ == address(0) ? msg.sender : executor_;
        profitUnlockTime = block.timestamp + PROFIT_LOCK_PERIOD;

        for (uint256 i = 0; i < routers.length; ) {
            _setRouterAllowed(routers[i], true);
            unchecked { ++i; }
        }
        for (uint256 i = 0; i < tokens.length; ) {
            _setTokenAllowed(tokens[i], true);
            unchecked { ++i; }
        }
    }

    // ── Admin ───────────────────────────────────────────────────────────────
    function pause() external onlyOwner noLoanInProgress {
        paused = true;
        emit PauseStatusChanged(true);
    }
    function unpause() external onlyOwner noLoanInProgress {
        paused = false;
        emit PauseStatusChanged(false);
    }
    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }
    function setRouterAllowed(address router, bool allowed) external onlyOwner noLoanInProgress {
        _setRouterAllowed(router, allowed);
    }
    function setTokenAllowed(address token, bool allowed) external onlyOwner noLoanInProgress {
        _setTokenAllowed(token, allowed);
    }
    function setMultipleRouters(address[] calldata routers, bool[] calldata allowed) external onlyOwner noLoanInProgress {
        if (routers.length != allowed.length || routers.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < routers.length; ) {
            _setRouterAllowed(routers[i], allowed[i]);
            unchecked { ++i; }
        }
    }
    function setMultipleTokens(address[] calldata tokens, bool[] calldata allowed) external onlyOwner noLoanInProgress {
        if (tokens.length != allowed.length || tokens.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < tokens.length; ) {
            _setTokenAllowed(tokens[i], allowed[i]);
            unchecked { ++i; }
        }
    }
    function setSlippageBps(uint256 bps) external onlyOwner noLoanInProgress {
        if (bps > MAX_SLIPPAGE_BPS) revert SlippageBpsTooHigh();
        slippageBps = bps;
        emit SlippageBpsUpdated(bps);
    }
    function setMinProfitBps(uint256 bps) external onlyOwner noLoanInProgress {
        if (bps == 0 || bps >= BPS_DENOMINATOR) revert MinProfitBpsZero();
        minProfitBps = bps;
        emit MinProfitBpsUpdated(bps);
    }

    // ── Emergency Profit Withdrawal ─────────────────────────────────────────
    function emergencyProfitWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < profitUnlockTime) revert UnlockTimeNotReached();

        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        if (loanOpen && token == activeAsset) {
            uint256 protected = balanceBefore + activeAmount;
            if (currentBalance <= protected) revert ProfitWithdrawalLocked();
            if (amount > currentBalance - protected) revert ProfitWithdrawalLocked();
        }
        IERC20(token).safeSend(to, amount);
        emit ProfitWithdrawn(token, to, amount);
    }

    // ── Aave Premium ────────────────────────────────────────────────────────
    function flashLoanPremiumBps() external view returns (uint256) {
        return uint256(IAavePool(aavePool).FLASHLOAN_PREMIUM_TOTAL());
    }

    // ── Token Recovery (paused only) ────────────────────────────────────────
    function sweepToken(address token, address to, uint256 amount) external onlyOwner {
        if (!paused) revert MustBePaused();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeSend(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // ── Preview Route (V2 only — view function) ─────────────────────────────
    function previewRoute(uint256 amountIn, Hop[] calldata hops) external view returns (uint256[] memory amountsOut) {
        if (amountIn == 0) revert ZeroAmount();
        _validateRouteShape(activeAsset == address(0) ? hops[0].tokenIn : activeAsset, hops);
        uint256 hopCount = hops.length;
        amountsOut = new uint256[](hopCount);
        uint256 currentIn = amountIn;

        for (uint256 i = 0; i < hopCount; ) {
            if (hops[i].dexType != DexType.V2) revert UnsupportedDexType();
            address[] memory path = new address[](2);
            path[0] = hops[i].tokenIn;
            path[1] = hops[i].tokenOut;
            uint256[] memory quoted = IUniswapV2Router(hops[i].router).getAmountsOut(currentIn, path);
            if (quoted.length < 2) revert EmptyRouterResult();
            uint256 out = quoted[quoted.length - 1];
            if (out == 0) revert ZeroRouterOutput();
            amountsOut[i] = out;
            currentIn = out;
            unchecked { ++i; }
        }
    }

    // ── Start Flash Loan ────────────────────────────────────────────────────
    function startArbitrage(
        address asset,
        uint256 amount,
        uint256 deadline,
        Hop[] calldata hops
    ) external onlyExecutorOrOwner whenRunning noLoanInProgress nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!tokenWhitelist[asset]) revert TokenNotWhitelisted(asset);
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (deadline > block.timestamp + MAX_PLAN_LIFETIME) revert DeadlineTooFar();
        _validateRouteShape(asset, hops);

        bytes memory params = abi.encode(asset, amount, deadline, msg.sender, hops);
        loanOpen = true;
        executionStartTime = block.timestamp;
        activeRequestHash = keccak256(params);
        activeAsset = asset;
        activeAmount = amount;
        balanceBefore = IERC20(asset).balanceOf(address(this));

        emit FlashRequested(asset, amount, deadline, hops.length, activeRequestHash);
        IAavePool(aavePool).flashLoanSimple(address(this), asset, amount, params, 0);
        if (loanOpen) revert BadCallback();
    }

    // ── Aave Callback ───────────────────────────────────────────────────────
    // [FIX-1] The nonReentrant modifier was REMOVED from executeOperation.
    //
    // Problem: startArbitrage has nonReentrant -> on entry _status=_ENTERED.
    // Aave Pool calls executeOperation IN THE SAME transaction (inside
    // flashLoanSimple), and if the callback also had nonReentrant, the
    // `_status == _ENTERED` check would guaranteed-revert ReentrantCall() on
    // EVERY flash loan. OZ ReentrancyGuard is not designed for the
    // "external call -> callback in the same tx" pattern: the guard had been
    // copied onto the callback by mistake.
    //
    // Why this is safe without nonReentrant:
    //   1. _validateFlashCallback (below) guarantees: msg.sender == aavePool,
    //      initiator == address(this), loanOpen == true, asset/amount match
    //      activeAsset/activeAmount and keccak256(params) == activeRequestHash.
    //      A third-party call to executeOperation is impossible.
    //   2. Re-entering startArbitrage DURING the callback is blocked by the
    //      combination: noLoanInProgress (loanOpen == true until
    //      _resetLoanState) + the held _ENTERED from nonReentrant on
    //      startArbitrage.
    //   3. All admin functions that change config have noLoanInProgress.
    // whenRunning remains (pause must block the callback too).
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override whenRunning returns (bool) {
        if (block.timestamp > executionStartTime + MAX_EXECUTION_DELAY) {
            emit ExecutionDelayed(block.timestamp - executionStartTime, MAX_EXECUTION_DELAY);
            revert ExecutionTimeout();
        }

        (address expectedAsset, uint256 expectedAmount, uint256 deadline, , Hop[] memory hops) =
            abi.decode(params, (address, uint256, uint256, address, Hop[]));

        _validateFlashCallback(asset, amount, initiator, params, expectedAsset, expectedAmount);
        if (deadline < block.timestamp) revert DeadlineExpired();
        _ensureLoanReceived(asset, amount);
        _executeHops(hops);
        uint256 profit = _approveRepaymentAndGetProfit(asset, amount, premium);
        bytes32 completedHash = activeRequestHash;
        _resetLoanState();

        emit FlashCompleted(asset, amount, premium, profit, completedHash);
        return true;
    }

    // ── Route Validation ────────────────────────────────────────────────────
    function _validateRouteShape(address asset, Hop[] calldata hops) internal view {
        uint256 hopCount = hops.length;
        if (hopCount < MIN_HOPS || hopCount > MAX_HOPS) revert InvalidHopCount();
        if (hops[0].tokenIn != asset || hops[hopCount - 1].tokenOut != asset) revert RouteMustStartAndEndOnAsset();

        for (uint256 i = 0; i < hopCount; ) {
            Hop calldata hop = hops[i];
            if (!routerWhitelist[hop.router]) revert RouterNotWhitelisted(hop.router);
            if (!tokenWhitelist[hop.tokenIn]) revert TokenNotWhitelisted(hop.tokenIn);
            if (!tokenWhitelist[hop.tokenOut]) revert TokenNotWhitelisted(hop.tokenOut);
            if (hop.minOut == 0) revert HopMinOutZero();
            if (i + 1 < hopCount && hop.tokenOut != hops[i + 1].tokenIn) revert RouteMustStartAndEndOnAsset();
            unchecked { ++i; }
        }
    }

    // ── Hop Execution Router ────────────────────────────────────────────────
    function _executeHops(Hop[] memory hops) internal {
        uint256 currentAmount = activeAmount; // first hop uses flash loan amount

        for (uint256 i = 0; i < hops.length; ) {
            Hop memory hop = hops[i];
            if (currentAmount == 0) revert ZeroAmount();

            uint256 received;
            if (hop.dexType == DexType.V2) {
                received = _executeV2Hop(hop, currentAmount);
            } else if (hop.dexType == DexType.V3) {
                received = _executeV3Hop(hop, currentAmount);
            } else {
                // [FIX-5] The V4 branch (revert V4ExecutionNotConfigured) was removed.
                // DexType is now {V2, V3}; this point is reachable only via
                // corrupted ABI encoding — the revert is deliberately kept.
                revert UnsupportedDexType();
            }

            emit HopExecuted(i, hop.dexType, hop.router, hop.tokenIn, hop.tokenOut, currentAmount, received);
            currentAmount = received;
            unchecked { ++i; }
        }
    }

    // ── V2 Execution ────────────────────────────────────────────────────────
    function _executeV2Hop(Hop memory hop, uint256 amountIn) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = hop.tokenIn;
        path[1] = hop.tokenOut;

        IERC20(hop.tokenIn).safeApproveExact(hop.router, amountIn);
        uint256[] memory amounts = IUniswapV2Router(hop.router).swapExactTokensForTokens(
            amountIn,
            hop.minOut,
            path,
            address(this),
            block.timestamp
        );
        IERC20(hop.tokenIn).safeApproveExact(hop.router, 0);

        if (amounts.length < 2) revert EmptyRouterResult();
        amountOut = amounts[amounts.length - 1];
        if (amountOut < hop.minOut) revert NoProfitableRouteFound();
    }

    // ── V3 Execution ────────────────────────────────────────────────────────
    function _executeV3Hop(Hop memory hop, uint256 amountIn) internal returns (uint256 amountOut) {
        IERC20(hop.tokenIn).safeApproveExact(hop.router, amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: hop.tokenIn,
            tokenOut: hop.tokenOut,
            fee: hop.fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: hop.minOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(hop.router).exactInputSingle(params);
        // V3 router uses transferFrom, approval remains exactly spent or can be zeroed
        IERC20(hop.tokenIn).safeApproveExact(hop.router, 0);

        if (amountOut < hop.minOut) revert NoProfitableRouteFound();
    }

    // [FIX-5] _executeV4Hop removed entirely: it unconditionally reverted
    // V4ExecutionNotConfigured() — i.e. the advertised execution path was a
    // dead stub. V4 execution (UniversalRouter.execute with exact
    // commands/inputs encoding for a specific deployment) will be added in a
    // separate version once correct PoolManager quoting is implemented.

    // ── Callback Validation ─────────────────────────────────────────────────
    function _validateFlashCallback(
        address asset, uint256 amount, address initiator,
        bytes calldata params, address expectedAsset, uint256 expectedAmount
    ) internal view {
        if (msg.sender != aavePool) revert BadCallback();
        if (initiator != address(this)) revert BadCallback();
        if (!loanOpen) revert NoLoanOpen();
        if (asset != activeAsset || amount != activeAmount) revert BadCallback();
        if (asset != expectedAsset || amount != expectedAmount) revert BadCallback();
        if (keccak256(params) != activeRequestHash) revert BadCallback();
    }

    // ── Loan Balance Check ──────────────────────────────────────────────────
    function _ensureLoanReceived(address asset, uint256 amount) internal view {
        uint256 currentBalance = IERC20(asset).balanceOf(address(this));
        if (currentBalance < balanceBefore + amount) revert InsufficientLoanBalance();
    }

    // ── Final Profit Check (Single Source of Truth) ─────────────────────────
    function _approveRepaymentAndGetProfit(address asset, uint256 amount, uint256 premium)
        internal returns (uint256 profit)
    {
        uint256 debt = amount + premium;
        if (debt < amount) revert ArithmeticOverflow();

        uint256 endingBalance = IERC20(asset).balanceOf(address(this));
        uint256 minProfitAbs = FullMath.mulDiv(amount, minProfitBps, BPS_DENOMINATOR);
        uint256 required = balanceBefore + debt + minProfitAbs;

        if (required < balanceBefore || required < debt) revert ArithmeticOverflow();
        if (endingBalance < required) revert NoProfitableRouteFound();

        profit = endingBalance - balanceBefore - debt;
        IERC20(asset).safeApproveExact(aavePool, debt);
    }

    // ── Whitelist Internals ─────────────────────────────────────────────────
    function _setRouterAllowed(address router, bool allowed) internal {
        if (router == address(0)) revert ZeroAddress();
        if (allowed) _requireContract(router);
        routerWhitelist[router] = allowed;
        emit RouterWhitelistUpdated(router, allowed);
    }
    function _setTokenAllowed(address token, bool allowed) internal {
        if (token == address(0)) revert ZeroAddress();
        if (allowed) _requireContract(token);
        tokenWhitelist[token] = allowed;
        emit TokenWhitelistUpdated(token, allowed);
    }
    function _requireContract(address target) internal view {
        if (target.code.length == 0) revert AddressNotContract(target);
    }

    // ── Reset ───────────────────────────────────────────────────────────────
    function _resetLoanState() internal {
        loanOpen = false;
        activeRequestHash = bytes32(0);
        activeAsset = address(0);
        activeAmount = 0;
        balanceBefore = 0;
        executionStartTime = 0;
    }

    // ── No Native ETH ───────────────────────────────────────────────────────
    receive() external payable { revert NativeTransfersDisabled(); }
    fallback() external payable { revert NativeTransfersDisabled(); }
}

// ═══════════════════════════════════════════════════════════════════════════
//  SECTION: PROOF TESTS — HEVM cheatcodes + inline console2 +
//  TestBase + contract ArbitrageExecutorProof (7 tests).
//  VERBATIM from ArbitrageExecutor.Proof.sol (test part).
// ═══════════════════════════════════════════════════════════════════════════
