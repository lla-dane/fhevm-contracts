// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { EncryptedERC20 } from "./EncryptedERC20.sol";

import "fhevm/lib/TFHE.sol";

/**
 * @title             EncryptedWETH
 * @notice            This contract allows users to wrap/unwrap trustlessly
 *                    ETH (or other native tokens) to EncryptedERC20 tokens.
 */
abstract contract EncryptedWETH is EncryptedERC20 {
    /// @notice Returned if the amount is greater than 2**64.
    error AmountTooHigh();

    /// @notice Returned if ETH transfer fails.
    error ETHTransferFail();

    /// @notice Emitted when encrypted wrapped ether is unwrapped.
    event Unwrap(address indexed to, uint64 amount);

    /// @notice Emitted when ether is wrapped.
    event Wrap(address indexed to, uint64 amount);

    /**
     * @notice         Deposit/withdraw ethers (or native tokens).
     * @dev            The name/symbol are autogenerated.
     */
    constructor()
        EncryptedERC20(string(abi.encodePacked("Encrypted Wrapped Ether")), string(abi.encodePacked("eWETH")))
    {}

    /**
     * @notice         Unwrap EncryptedERC20 tokens to ether.
     * @param amount   Amount to unwrap.
     */
    function unwrap(uint64 amount) public virtual {
        _balances[msg.sender] = TFHE.sub(_balances[msg.sender], amount);
        TFHE.allowThis(_balances[msg.sender]);
        TFHE.allow(_balances[msg.sender], msg.sender);

        _totalSupply -= amount;

        /// @dev It does a supply adjustment.
        uint256 amountUint256 = amount * (10 ** (18 - decimals()));

        /* solhint-disable avoid-call-value*/
        /* solhint-disable avoid-low-level-calls*/
        (bool callSuccess, ) = msg.sender.call{ value: amountUint256 }("");

        if (!callSuccess) {
            revert ETHTransferFail();
        }

        emit Unwrap(msg.sender, amount);
    }

    /**
     * @notice         Wrap ether to an encrypted format.
     */
    function wrap() public payable virtual {
        uint256 amountAdjusted = msg.value / (10 ** (18 - decimals()));

        if (amountAdjusted > type(uint64).max) {
            revert AmountTooHigh();
        }

        uint64 amountUint64 = uint64(amountAdjusted);

        _balances[msg.sender] = TFHE.add(_balances[msg.sender], amountUint64);

        TFHE.allowThis(_balances[msg.sender]);
        TFHE.allow(_balances[msg.sender], msg.sender);

        _totalSupply += amountUint64;

        emit Wrap(msg.sender, amountUint64);
    }
}
