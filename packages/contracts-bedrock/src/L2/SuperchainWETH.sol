// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { WETH98 } from "src/dispute/weth/WETH98.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { L1Block } from "src/L2/L1Block.sol";
import { IL2ToL2CrossDomainMessenger } from "src/L2/IL2ToL2CrossDomainMessenger.sol";
import { ETHLiquidity } from "src/L2/ETHLiquidity.sol";
import { ISemver } from "src/universal/ISemver.sol";

import "src/libraries/errors/CommonErrors.sol";

/// @title SuperchainWETH
/// @notice SuperchainWETH is a version of WETH that can be freely transfered between chains within
///         the superchain. SuperchainWETH can be converted into native ETH on chains that do not
//          use a custom gas token.
contract SuperchainWETH is WETH98, ISemver {
    /// @notice Semantic version.
    /// @custom:semver 1.0.0
    string public constant version = "1.0.0-beta.1";

    /// @inheritdoc WETH98
    function deposit() public payable override {
        if (L1Block(Predeploys.L1_BLOCK_ATTRIBUTES).isCustomGasToken()) revert NotCustomGasToken();
        super.deposit();
    }

    /// @inheritdoc WETH98
    function withdraw(uint256 wad) public override {
        if (L1Block(Predeploys.L1_BLOCK_ATTRIBUTES).isCustomGasToken()) revert NotCustomGasToken();
        super.withdraw(wad);
    }

    /// TODO: .inheritdoc ISuperchainERC20
    function sendERC20(uint256 wad, uint256 chainId) external {
        sendERC20To(msg.sender, wad, chainId);
    }

    /// TODO: .inheritdoc ISuperchainERC20
    function sendERC20To(address dst, uint256 wad, uint256 chainId) public {
        // Burn from user's balance.
        _burn(msg.sender, wad);

        // Burn to ETHLiquidity contract.
        if (!L1Block(Predeploys.L1_BLOCK_ATTRIBUTES).isCustomGasToken()) {
            ETHLiquidity(Predeploys.ETH_LIQUIDITY).burn{ value: wad }();
        }

        // Send message to other chain.
        IL2ToL2CrossDomainMessenger(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER).sendMessage({
            _destination: chainId,
            _target: address(this),
            _message: abi.encodeCall(this.finalizeSendERC20, (dst, wad))
        });
    }

    /// TODO: .inheritdoc ISuperchainERC20
    function finalizeSendERC20(address dst, uint256 wad) external {
        // Receive message from other chain.
        IL2ToL2CrossDomainMessenger messenger = IL2ToL2CrossDomainMessenger(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        if (msg.sender != address(messenger)) revert Unauthorized();
        if (messenger.crossDomainMessageSender() != address(this)) revert Unauthorized();

        // Mint from ETHLiquidity contract.
        if (!L1Block(Predeploys.L1_BLOCK_ATTRIBUTES).isCustomGasToken()) {
            ETHLiquidity(Predeploys.ETH_LIQUIDITY).mint(wad);
        }

        // Mint to user's balance.
        _mint(dst, wad);
    }

    /// @notice Mints WETH to an address.
    /// @param guy The address to mint WETH to.
    /// @param wad The amount of WETH to mint.
    function _mint(address guy, uint256 wad) internal {
        balanceOf[guy] += wad;
        emit Transfer(address(0), guy, wad);
    }

    /// @notice Burns WETH from an address.
    /// @param guy The address to burn WETH from.
    /// @param wad The amount of WETH to burn.
    function _burn(address guy, uint256 wad) internal {
        require(balanceOf[guy] >= wad);
        balanceOf[guy] -= wad;
        emit Transfer(guy, address(0), wad);
    }
}
