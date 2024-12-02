// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";

/**
 * @title       IConfidentialERC20Votes
 * @dev         The ConfidentialGovernorAlpha relies on this interface.
 */
interface IConfidentialERC20Votes {
    /**
     * @notice              Determine the prior number of votes for an account as of a block number.
     * @dev                 Block number must be a finalized block or else this function will revert.
     *                      This function can change the state since the governor needs access in the ACL
     *                      contract.
     * @param account       Account address.
     * @param blockNumber   The block number to get the vote balance at.
     * @return votes        Number of votes the account as of the given block number.
     */
    function getPriorVotesForGovernor(address account, uint256 blockNumber) external returns (euint64 votes);
}
