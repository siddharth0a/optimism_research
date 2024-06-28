// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing utilities
import { CommonTest } from "test/setup/CommonTest.sol";

// Contract imports
import { Predeploys } from "src/libraries/Predeploys.sol";
import { IL2ToL2CrossDomainMessenger } from "src/L2/IL2ToL2CrossDomainMessenger.sol";
import { ETHLiquidity } from "src/L2/ETHLiquidity.sol";

// Error imports
import "src/libraries/errors/CommonErrors.sol";

/// @title SuperchainWETH_Test
/// @notice Contract for testing the SuperchainWETH contract.
contract SuperchainWETH_Test is CommonTest {
    /// @notice Emitted when a transfer is made.
    event Transfer(address indexed src, address indexed dst, uint256 wad);

    /// @notice Emitted when a deposit is made.
    event Deposit(address indexed dst, uint256 wad);

    /// @notice Emitted when a withdrawal is made.
    event Withdrawal(address indexed src, uint256 wad);

    /// @notice Test setup.
    function setUp() public virtual override {
        super.enableInterop();
        super.setUp();
    }

    /// @notice Tests that the deposit function can be called on a non-custom gas token chain.
    function test_deposit_fromNonCustomGasTokenChain_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(alice, amount);

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Deposit(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), amount);
    }

    /// @notice Tests that the deposit function reverts when called on a custom gas token chain.
    function test_deposit_fromCustomGasTokenChain_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(address(alice), amount);
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.prank(alice);
        vm.expectRevert(NotCustomGasToken.selector);
        superchainWeth.deposit{ value: amount }();

        // Assert
        assertEq(alice.balance, amount);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the withdraw function can be called on a non-custom gas token chain.
    function test_withdraw_fromNonCustomGasTokenChain_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Withdrawal(alice, amount);
        vm.prank(alice);
        superchainWeth.withdraw(amount);

        // Assert
        assertEq(alice.balance, amount);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the withdraw function reverts when called on a custom gas token chain.
    function test_withdraw_fromCustomGasTokenChain_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.prank(alice);
        vm.expectRevert(NotCustomGasToken.selector);
        superchainWeth.withdraw(amount);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), amount);
    }

    /// @notice Tests that the sendERC20 function can be called with a sufficient balance on a
    ///         non-custom gas token chain. Also tests that the proper calls are made, ETH is
    ///         burned, and the proper events are emitted.
    function test_sendERC20_sufficientBalance_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(alice, address(0), amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 1);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (
                    chainId,
                    address(superchainWeth),
                    abi.encodeWithSelector(superchainWeth.finalizeSendERC20.selector, alice, amount)
                )
            ),
            1
        );
        vm.prank(alice);
        superchainWeth.sendERC20(amount, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the sendERC20 function can be called with a sufficient balance on a
    ///         custom gas token chain. Also tests that the proper calls are made and the proper
    ///         events are emitted but ETH is not burned via the ETHLiquidity contract.
    function test_sendERC20_sufficientFromCustomGasTokenChain_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(alice, address(0), amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 0);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (
                    chainId,
                    address(superchainWeth),
                    abi.encodeWithSelector(superchainWeth.finalizeSendERC20.selector, alice, amount)
                )
            ),
            1
        );
        vm.prank(alice);
        superchainWeth.sendERC20(amount, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the sendERC20 function reverts when called with insufficient balance.
    function test_sendERC20_insufficientBalance_fails() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Act
        vm.expectRevert();
        superchainWeth.sendERC20(amount + 1, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), amount);
    }

    /// @notice Tests that the sendERC20 function always succeeds when called with a sufficient
    ///         balance no matter the sender, amount, or chain ID.
    /// @param _amount The amount of WETH to send.
    /// @param _caller The address of the caller.
    /// @param _chainId The chain ID to send the WETH to.
    function testFuzz_sendERC20_sufficientBalance_succeeds(uint256 _amount, address _caller, uint256 _chainId) public {
        // Arrange
        vm.deal(_caller, _amount);
        vm.prank(_caller);
        superchainWeth.deposit{ value: _amount }();

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(_caller, address(0), _amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 1);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (
                    _chainId,
                    address(superchainWeth),
                    abi.encodeCall(superchainWeth.finalizeSendERC20, (_caller, _amount))
                )
            ),
            1
        );
        vm.prank(_caller);
        superchainWeth.sendERC20(_amount, _chainId);

        // Assert
        assertEq(_caller.balance, 0);
        assertEq(superchainWeth.balanceOf(_caller), 0);
    }

    /// @notice Tests that the sendERC20To function can be called with a sufficient balance on a
    ///         non-custom gas token chain. Also tests that the proper calls are made, ETH is
    ///         burned, and the proper events are emitted.
    function test_sendERC20To_sufficientBalance_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(alice, address(0), amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 1);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (chainId, address(superchainWeth), abi.encodeCall(superchainWeth.finalizeSendERC20, (bob, amount)))
            ),
            1
        );
        vm.prank(alice);
        superchainWeth.sendERC20To(bob, amount, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the sendERC20To function can be called with a sufficient balance on a
    ///         custom gas token chain. Also tests that the proper calls are made and the proper
    ///         events are emitted but ETH is not burned via the ETHLiquidity contract.
    function test_sendERC20To_sufficientFromCustomGasTokenChain_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(alice, address(0), amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 0);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (chainId, address(superchainWeth), abi.encodeCall(superchainWeth.finalizeSendERC20, (bob, amount)))
            ),
            1
        );
        vm.prank(alice);
        superchainWeth.sendERC20To(bob, amount, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), 0);
    }

    /// @notice Tests that the sendERC20To function reverts when called with insufficient balance.
    function test_sendERC20To_insufficientBalance_fails() public {
        // Arrange
        uint256 amount = 1000;
        uint256 chainId = 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        superchainWeth.deposit{ value: amount }();

        // Act
        vm.expectRevert();
        superchainWeth.sendERC20To(bob, amount + 1, chainId);

        // Assert
        assertEq(alice.balance, 0);
        assertEq(superchainWeth.balanceOf(alice), amount);
    }

    /// @notice Tests that the sendERC20To function always succeeds when called with a sufficient
    ///         balance no matter the sender, amount, recipient, or chain ID.
    /// @param _amount The amount of WETH to send.
    /// @param _caller The address of the caller.
    /// @param _recipient The address of the recipient.
    /// @param _chainId The chain ID to send the WETH to.
    function testFuzz_sendERC20To_sufficientBalance_succeeds(
        uint256 _amount,
        address _caller,
        address _recipient,
        uint256 _chainId
    )
        public
    {
        // Arrange
        vm.deal(_caller, _amount);
        vm.prank(_caller);
        superchainWeth.deposit{ value: _amount }();

        // Act
        vm.expectEmit(address(superchainWeth));
        emit Transfer(_caller, address(0), _amount);
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.burn, ()), 1);
        vm.expectCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(
                IL2ToL2CrossDomainMessenger.sendMessage,
                (
                    _chainId,
                    address(superchainWeth),
                    abi.encodeCall(superchainWeth.finalizeSendERC20, (_recipient, _amount))
                )
            ),
            1
        );
        vm.prank(_caller);
        superchainWeth.sendERC20To(_recipient, _amount, _chainId);

        // Assert
        assertEq(_caller.balance, 0);
        assertEq(superchainWeth.balanceOf(_caller), 0);
    }

    /// @notice Tests that the finalizeSendERC20 function can be called from the
    ///         L2ToL2CrossDomainMessenger as long as the crossDomainMessageSender is the
    function test_finalizeSendERC20_fromMessenger_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(IL2ToL2CrossDomainMessenger.crossDomainMessageSender, ()),
            abi.encode(address(superchainWeth))
        );

        // Act
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.mint, (amount)), 1);
        vm.prank(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        superchainWeth.finalizeSendERC20(bob, amount);

        // Assert
        assertEq(address(superchainWeth).balance, amount);
        assertEq(superchainWeth.balanceOf(bob), amount);
    }

    /// @notice Tests that the finalizeSendERC20 function can be called from the
    ///         L2ToL2CrossDomainMessenger as long as the crossDomainMessageSender is the
    ///         SuperchainWETH contract, even when the chain is a custom gas token chain. Shows
    ///         that ETH is not minted in this case but the SuperchainWETH balance is updated.
    function test_finalizeSendERC20_fromMessengerCustomGasTokenChain_succeeds() public {
        // Arrange
        uint256 amount = 1000;
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(IL2ToL2CrossDomainMessenger.crossDomainMessageSender, ()),
            abi.encode(address(superchainWeth))
        );
        vm.mockCall(address(l1Block), abi.encodeCall(l1Block.isCustomGasToken, ()), abi.encode(true));

        // Act
        vm.expectCall(Predeploys.ETH_LIQUIDITY, abi.encodeCall(ETHLiquidity.mint, (amount)), 0);
        vm.prank(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        superchainWeth.finalizeSendERC20(bob, amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(superchainWeth.balanceOf(bob), amount);
    }

    /// @notice Tests that the finalizeSendERC20 function reverts when not called from the
    ///         L2ToL2CrossDomainMessenger.
    function test_finalizeSendERC20_notFromMessenger_fails() public {
        // Arrange
        uint256 amount = 1000;

        // Act
        vm.expectRevert(Unauthorized.selector);
        vm.prank(alice);
        superchainWeth.finalizeSendERC20(bob, amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(superchainWeth.balanceOf(bob), 0);
    }

    /// @notice Tests that the finalizeSendERC20 function reverts when called from the
    ///         L2ToL2CrossDomainMessenger but the crossDomainMessageSender is not the
    ///         SuperchainWETH contract.
    function test_finalizeSendERC20_fromMessengerNotFromSuperchainWETH_fails() public {
        // Arrange
        uint256 amount = 1000;
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeCall(IL2ToL2CrossDomainMessenger.crossDomainMessageSender, ()),
            abi.encode(address(alice))
        );

        // Act
        vm.expectRevert(Unauthorized.selector);
        vm.prank(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        superchainWeth.finalizeSendERC20(bob, amount);

        // Assert
        assertEq(address(superchainWeth).balance, 0);
        assertEq(superchainWeth.balanceOf(bob), 0);
    }
}
