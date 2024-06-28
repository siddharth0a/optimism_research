// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing utilities
import { CommonTest } from "test/setup/CommonTest.sol";

// Error imports
import "src/libraries/errors/CommonErrors.sol";

/// @title ETHLiquidity_Test
/// @notice Contract for testing the ETHLiquidity contract.
contract ETHLiquidity_Test is CommonTest {
    /// @notice Emitted when an address burns ETH liquidity.
    event LiquidityBurned(address indexed caller, uint256 value);

    /// @notice Emitted when an address mints ETH liquidity.
    event LiquidityMinted(address indexed caller, uint256 value);

    /// @notice The starting balance of the ETHLiquidity contract.
    uint256 public constant STARTING_LIQUIDITY_BALANCE = type(uint248).max;

    /// @notice Test setup.
    function setUp() public virtual override {
        super.enableInterop();
        super.setUp();
    }

    /// @notice Tests that the burn function can be called by an authorized caller.
    function test_burn_fromAuthorizedCaller_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(address(superchainWeth), amount);

        // Act
        vm.expectEmit(address(ethLiquidity));
        emit LiquidityBurned(address(superchainWeth), amount);
        vm.prank(address(superchainWeth));
        ethLiquidity.burn{ value: amount }();

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE + amount);
    }

    /// @notice Tests that the burn function reverts when called by an unauthorized caller.
    function test_burn_fromUnauthorizedCaller_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(address(superchainWeth), amount);

        // Act
        vm.expectRevert(Unauthorized.selector);
        ethLiquidity.burn{ value: amount }();

        // Assert
        assertEq(address(superchainWeth).balance, amount);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
    }

    /// @notice Tests that the burn function reverts when called on a custom gas token chain.
    function test_burn_fromCustomGasTokenChain_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(address(superchainWeth), amount);
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.prank(address(superchainWeth));
        vm.expectRevert(NotCustomGasToken.selector);
        ethLiquidity.burn{ value: amount }();

        // Assert
        assertEq(address(superchainWeth).balance, amount);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
    }

    /// @notice Tests that the burn function can always be called by an authorized caller.
    /// @param _amount Amount of ETH (in wei) to call the burn function with.
    function testFuzz_burn_fromAuthorizedCaller_succeeds(uint256 _amount) public {
        // Assume
        vm.assume(_amount < type(uint248).max);

        // Arrange
        vm.deal(address(superchainWeth), _amount);

        // Act
        vm.expectEmit(address(ethLiquidity));
        emit LiquidityBurned(address(superchainWeth), _amount);
        vm.prank(address(superchainWeth));
        ethLiquidity.burn{ value: _amount }();

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE + _amount);
    }

    /// @notice Tests that the burn function always reverts when called by an unauthorized caller.
    /// @param _amount Amount of ETH (in wei) to call the burn function with.
    /// @param _caller Address of the caller to call the burn function with.
    function testFuzz_burn_fromUnauthorizedCaller_fails(uint256 _amount, address _caller) public {
        // Assume
        vm.assume(_amount < type(uint248).max);
        vm.assume(_caller != address(superchainWeth));

        // Arrange
        vm.deal(_caller, _amount);

        // Act
        vm.prank(_caller);
        vm.expectRevert(Unauthorized.selector);
        ethLiquidity.burn{ value: _amount }();

        // Assert
        assertEq(_caller.balance, _amount);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
    }

    /// @notice Tests that the mint function can be called by an authorized caller.
    function test_mint_fromAuthorizedCaller_succeeds() public {
        // Arrange
        uint256 amount = 1000;

        // Act
        vm.expectEmit(address(ethLiquidity));
        emit LiquidityMinted(address(superchainWeth), amount);
        vm.prank(address(superchainWeth));
        ethLiquidity.mint(amount);

        // Assert
        assertEq(address(superchainWeth).balance, amount);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE - amount);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }

    /// @notice Tests that the mint function reverts when called by an unauthorized caller.
    function test_mint_fromUnauthorizedCaller_fails() public {
        // Arrange
        uint256 amount = 1000;

        // Act
        vm.expectRevert(Unauthorized.selector);
        ethLiquidity.mint(amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }

    /// @notice Tests that the mint function reverts when called on a custom gas token chain.
    function test_mint_fromCustomGasTokenChain_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.prank(address(superchainWeth));
        vm.expectRevert(NotCustomGasToken.selector);
        ethLiquidity.mint(amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }

    /// @notice Tests that the mint function fails when the amount requested is greater than the
    ///         available balance. In practice this should never happen because the starting
    ///         balance is expected to be uint248 wei, the total ETH supply is far less than that
    ///         amount, and the only contract that pulls from here is the SuperchainWETH contract
    ///         which will always burn ETH somewhere before minting it somewhere else. It needs to
    ///         be a system-wide invariant that this condition is never triggered in the first
    ///         place but it is the behavior we expect if it does happen.
    function test_mint_moreThanAvailableBalance_fails() public {
        // Arrange
        uint256 amount = STARTING_LIQUIDITY_BALANCE + 1;

        // Act
        vm.expectRevert();
        ethLiquidity.mint(amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }

    /// @notice Tests that the mint function can always be called by an authorized caller.
    /// @param _amount Amount of ETH (in wei) to call the mint function with.
    function testFuzz_mint_fromAuthorizedCaller_succeeds(uint256 _amount) public {
        // Assume
        vm.assume(_amount < type(uint248).max);

        // Arrange
        // Nothing to arrange.

        // Act
        vm.expectEmit(address(ethLiquidity));
        emit LiquidityMinted(address(superchainWeth), _amount);
        vm.prank(address(superchainWeth));
        ethLiquidity.mint(_amount);

        // Assert
        assertEq(address(superchainWeth).balance, _amount);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE - _amount);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }

    /// @notice Tests that the mint function always reverts when called by an unauthorized caller.
    /// @param _amount Amount of ETH (in wei) to call the mint function with.
    /// @param _caller Address of the caller to call the mint function with.
    function testFuzz_mint_fromUnauthorizedCaller_fails(uint256 _amount, address _caller) public {
        // Assume
        vm.assume(_amount < type(uint248).max);
        vm.assume(_caller != address(superchainWeth));
        vm.assume(address(_caller).balance == 0);

        // Arrange
        // Nothing to arrange.

        // Act
        vm.prank(_caller);
        vm.expectRevert(Unauthorized.selector);
        ethLiquidity.mint(_amount);

        // Assert
        assertEq(_caller.balance, 0);
        assertEq(address(ethLiquidity).balance, STARTING_LIQUIDITY_BALANCE);
        assertEq(superchainWeth.balanceOf(address(ethLiquidity)), 0);
    }
}
