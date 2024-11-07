// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IComp } from "./IComp.sol";
import { ICompoundTimelock } from "./ICompoundTimelock.sol";

/**
 * @title       GovernorAlphaZama
 * @notice      This is based on the GovernorAlpha.sol contract written by Compound Labs.
 *              see: compound-finance/compound-protocol/blob/master/contracts/Governance/GovernorAlpha.sol
 *              This decentralized governance system allows users to propose and vote on changes to the protocol.
 *              The contract is responsible for:
 *              - Proposal: A new proposal is made to introduce a change.
 *              - Voting: Users can vote on the proposal, either in favor or against it.
 *              - Quorum: A minimum number of votes (quorum) must be reached for the proposal to pass.
 *              - Execution: Once a proposal passes, it is executed and takes effect on the protocol.
 */
abstract contract GovernorAlphaZama is Ownable2Step, GatewayCaller {
    /// @notice Returned if proposal contains too many changes.
    error LengthAboveMaxOperations();

    /// @notice Returned if the array length is equal to 0.
    error LengthIsNull();

    /// @notice Returned if array lengths are not equal.
    error LengthsDoNotMatch();

    /// @notice Returned if proposal's actions have already been queued.
    error ProposalActionsAlreadyQueued();

    /// @notice Returned if the proposal state is invalid for this operation.
    /// @dev    It is returned for any proposal state not matching the expected
    ///         state to conduct the operation.
    error ProposalStateInvalid();

    /// @notice Returned if the proposal's state is active but `block.number` > `endBlock`.
    error ProposalStateNotActive();

    /// @notice Returned if the proposal state is still active.
    error ProposalStateStillActive();

    /// @notice Returned if the proposer has another proposal in progress.
    error ProposerHasAnotherProposal();

    /// @notice Returned if the voter has already cast a vote
    ///         for this proposal.
    error VoterHasAlreadyVoted();

    /// @notice Emitted when a proposal is now active.
    event ProposalActive(uint256 id);

    /// @notice Emitted when a proposal has been canceled.
    event ProposalCanceled(uint256 id);

    /// @notice Emitted when a new proposal is created.
    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    /// @notice Emitted when a proposal is defeated either by lack of votes or by
    ///         more votes against.
    event ProposalDefeated(uint256 id);

    /// @notice Emitted when a proposal has been executed in the Timelock.
    event ProposalExecuted(uint256 id);

    /// @notice Emitted when a proposal has been queued in the Timelock.
    event ProposalQueued(uint256 id, uint256 eta);

    /// @notice Emitted when a proposal has been rejected since the number of votes is lower
    ///         than the required threshold.
    event ProposalRejected(uint256 id);

    /// @notice Emitted when a proposal has been rejected since the number of votes is lower
    ///         than the required threshold.
    event ProposalSucceeded(uint256 id);

    /// @notice Emitted when a vote has been cast on a proposal.
    event VoteCast(address voter, uint256 proposalId);

    /// @notice Possible states that a proposal may be in.
    enum ProposalState {
        Pending, /// Proposal does not exist.
        PendingThresholdVerification, /// Proposal is created but token threshold verification is pending.
        Rejected, /// Proposal was rejected because the proposer did not match the token threshold required.
        Active, /// Proposal is active and voters can cast their votes.
        PendingResults, /// Proposal is active but the decryption of the result is in progress.
        Canceled, /// Proposal has been canceled by the proposer.
        Defeated, /// Proposal has been defeated (either by not reaching the quorum or `votesAgainst` > `votesFor`).
        Succeeded, /// Proposal has succeeded.
        Queued, /// Proposal has been queued in the timelock.
        Expired, /// Proposal has expired (@dev This state is used for read-only operations).
        Executed /// Proposal has been executed.
    }

    /**
     * @param proposer              Proposal creator.
     * @param eta                   The timestamp that the proposal will be available for execution,
     *                              it is set automatically once the vote succeeds.
     * @param targets               The ordered list of target addresses for calls to be made.
     * @param values                The ordered list of values (i.e. `msg.value`) to be passed to the calls to be made.
     * @param signatures            The ordered list of function signatures to be called.
     * @param calldatas             The ordered list of calldata to be passed to each call.
     * @param startBlock            The block at which voting begins: holders must delegate their votes prior
     *                              to this block.
     * @param endBlock              The block at which voting ends: votes must be cast prior to this block.
     * @param forVotes              Current encrypted number of votes for to this proposal.
     * @param againstVotes          Current encrypted number of votes in opposition to this proposal.
     * @param forVotesDecrypted     For votes once decrypted by the gateway.
     * @param againstVotesDecrypted Against votes once decrypted by the gateway.
     */

    struct Proposal {
        address proposer;
        ProposalState state;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        euint64 forVotes;
        euint64 againstVotes;
        uint64 forVotesDecrypted;
        uint64 againstVotesDecrypted;
    }

    /**
     * @param proposer      Proposal creator.
     * @param state         State of the proposal.
     * @param eta           The timestamp when the proposal will be available for execution, set once the vote succeeds.
     * @param targets       The ordered list of target addresses for calls to be made.
     * @param values        The ordered list of values (i.e. `msg.value`) to be passed to the calls to be made.
     * @param signatures    The ordered list of function signatures to be called.
     * @param calldatas     The ordered list of calldata to be passed to each call.
     * @param startBlock    The block at which voting begins: holders must delegate their votes prior to this block.
     * @param endBlock      The block at which voting ends: votes must be cast prior to this block.
     * @param forVotes      Number of votes for this proposal once decrypted.
     * @param againstVotes  Number of votes in opposition to this proposal once decrypted.
     */
    struct ProposalInfo {
        address proposer;
        ProposalState state;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint64 forVotes;
        uint64 againstVotes;
    }

    /**
     * @notice          Ballot receipt record for a voter.
     * @param hasVoted  Whether or not a vote has been cast.
     * @param support   Whether or not the voter supports the proposal.
     * @param votes     The number of votes cast by the voter.
     */
    struct Receipt {
        bool hasVoted;
        ebool support;
        euint64 votes;
    }

    /// @notice The maximum number of actions that can be included in a proposal.
    /// @dev    It is 10 actions per proposal.
    uint256 public constant PROPOSAL_MAX_OPERATIONS = 10;

    /// @notice The number of votes required for a voter to become a proposer.
    /// @dev    It is set at 100,000, which is 1% of the total supply of the Comp token.
    uint256 public constant PROPOSAL_THRESHOLD = 100000e6;

    /// @notice The number of votes in support of a proposal required in order for a quorum to be reached
    ///         and for a vote to succeed.
    /// @dev    It is set at 400,000, which is 4% of the total supply of the Comp token.
    uint64 public constant QUORUM_VOTES = 400000e6;

    /// @notice The delay before voting on a proposal may take place once proposed.
    ///         It is 1 block.
    uint256 public constant VOTING_DELAY = 1;

    /// @notice The duration of voting on a proposal, in blocks
    /// @dev    It is recommended to be set at 3 days in blocks
    ///         (i.e 21,600 for 12-second blocks).
    uint256 public immutable VOTING_PERIOD;

    /// @notice Comp governance token.
    IComp public immutable COMP;

    /// @notice Compound Timelock.
    ICompoundTimelock public immutable TIMELOCK;

    /// @notice Constant for zero using TFHE.
    /// @dev    Since it is expensive to compute 0, it is stored instead.
    ///         However, is not possible to define it as constant due to TFHE constraints.
    /* solhint-disable var-name-mixedcase*/
    euint64 private _EUINT64_ZERO;

    /// @notice Constant for PROPOSAL_THRESHOLD using TFHE.
    /// @dev    Since it is expensive to compute 0, it is stored instead.
    ///         However, is not possible to define it as constant due to TFHE constraints.
    /* solhint-disable var-name-mixedcase*/
    euint64 private _EUINT64_PROPOSAL_THRESHOLD;

    /// @notice The total number of proposals made.
    ///         It includes all proposals, including the ones that
    ///         were rejected/canceled/defeated.
    uint256 public proposalCount;

    /// @notice The latest proposal for each proposer.
    mapping(address proposer => uint256 proposalId) public latestProposalIds;

    /// @notice Ballot receipt for an account for a proposal id.
    mapping(uint256 proposalId => mapping(address => Receipt)) internal _accountReceiptForProposalId;

    /// @notice The official record of all proposals that have been created.
    mapping(uint256 proposalId => Proposal proposal) internal _proposals;

    /// @notice Returns the proposal id associated with the request id from the Gateway.
    /// @dev    This mapping is used for decryption.
    mapping(uint256 requestId => uint256 proposalId) internal _requestIdToProposalId;

    /**
     * @param owner_            Owner address.
     * @param timelock_         Timelock contract.
     * @param comp_             Comp token.
     * @param votingPeriod_     Voting period.
     * @dev                     Do not use a small value in production such as 5 or 20 to avoid security issues
     *                          unless for testing purpose. It should by at least a few days,.
     *                          For instance, 3 days would have a votingPeriod = 21,600 blocks if 12s per block.
     */
    constructor(address owner_, address timelock_, address comp_, uint256 votingPeriod_) Ownable(owner_) {
        TIMELOCK = ICompoundTimelock(timelock_);
        COMP = IComp(comp_);
        VOTING_PERIOD = votingPeriod_;

        // @dev Store these constant-like variables in the storage.
        _EUINT64_ZERO = TFHE.asEuint64(0);
        _EUINT64_PROPOSAL_THRESHOLD = TFHE.asEuint64(PROPOSAL_THRESHOLD);

        TFHE.allowThis(_EUINT64_ZERO);
        TFHE.allowThis(_EUINT64_PROPOSAL_THRESHOLD);
    }

    /**
     * @notice              Cancel the proposal.
     * @param proposalId    Proposal id.
     * @dev                 Only the owner address or the proposer can cancel.
     *                      In the original GovernorAlpha, the proposer can cancel only if
     *                      her votes are still above the threshold.
     */
    function cancel(uint256 proposalId) external {
        Proposal memory proposal = _proposals[proposalId];

        if (
            proposal.state == ProposalState.Pending ||
            proposal.state == ProposalState.Executed ||
            proposal.state == ProposalState.Canceled ||
            proposal.state == ProposalState.Defeated
        ) {
            revert ProposalStateInvalid();
        }

        if (msg.sender != proposal.proposer) {
            _checkOwner();
        }

        /// @dev It is not necessary to cancel the transaction in the timelock
        ///      unless the proposal has been queued.
        if (proposal.state == ProposalState.Queued) {
            for (uint256 i = 0; i < proposal.targets.length; i++) {
                TIMELOCK.cancelTransaction(
                    proposal.targets[i],
                    proposal.values[i],
                    proposal.signatures[i],
                    proposal.calldatas[i],
                    proposal.eta
                );
            }
        }

        _proposals[proposalId].state = ProposalState.Canceled;

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice           Cast a vote.
     * @param proposalId Proposal id.
     * @param value      Encrypted value.
     * @param inputProof Input proof.
     */
    function castVote(uint256 proposalId, einput value, bytes calldata inputProof) external {
        return _castVote(msg.sender, proposalId, TFHE.asEbool(value, inputProof));
    }

    /**
     * @notice           Cast a vote.
     * @param proposalId Proposal id.
     * @param support    Support (true ==> votesFor, false ==> votesAgainst)
     */
    function castVote(uint256 proposalId, ebool support) external {
        return _castVote(msg.sender, proposalId, support);
    }

    /**
     * @notice Execute the proposal id.
     * @dev    Anyone can execute a proposal once it has been queued and the
     *         delay in the timelock is sufficient.
     */
    function execute(uint256 proposalId) external payable {
        Proposal memory proposal = _proposals[proposalId];

        if (proposal.state != ProposalState.Queued) {
            revert ProposalStateInvalid();
        }

        // proposal.executed = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            TIMELOCK.executeTransaction{ value: proposal.values[i] }(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }

        _proposals[proposalId].state = ProposalState.Executed;

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice            Start a new proposal.
     * @param targets     Target addresses.
     * @param values      Values.
     * @param signatures  Signatures.
     * @param calldatas   Calldatas.
     * @param description Plain text description of the proposal.
     * @return proposalId Proposal id.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId) {
        {
            uint256 length = targets.length;

            if (length != values.length || length != signatures.length || length != calldatas.length) {
                revert LengthsDoNotMatch();
            }

            if (length == 0) {
                revert LengthIsNull();
            }

            if (length > PROPOSAL_MAX_OPERATIONS) {
                revert LengthAboveMaxOperations();
            }
        }

        uint256 latestProposalId = latestProposalIds[msg.sender];

        if (latestProposalId != 0) {
            ProposalState proposerLatestProposalState = _proposals[latestProposalId].state;

            if (
                proposerLatestProposalState != ProposalState.Queued &&
                proposerLatestProposalState != ProposalState.Rejected &&
                proposerLatestProposalState != ProposalState.Defeated &&
                proposerLatestProposalState != ProposalState.Canceled &&
                proposerLatestProposalState != ProposalState.Executed
            ) {
                revert ProposerHasAnotherProposal();
            }
        }

        uint256 startBlock = block.number + VOTING_DELAY;
        uint256 endBlock = startBlock + VOTING_PERIOD;
        uint256 thisProposalId = ++proposalCount;

        _proposals[thisProposalId] = Proposal({
            proposer: msg.sender,
            state: ProposalState.PendingThresholdVerification,
            eta: 0,
            targets: targets,
            values: values,
            signatures: signatures,
            calldatas: calldatas,
            startBlock: startBlock,
            endBlock: endBlock,
            forVotes: _EUINT64_ZERO,
            againstVotes: _EUINT64_ZERO,
            forVotesDecrypted: 0,
            againstVotesDecrypted: 0
        });

        latestProposalIds[msg.sender] = thisProposalId;

        emit ProposalCreated(
            thisProposalId,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );

        ebool canPropose = TFHE.lt(
            _EUINT64_PROPOSAL_THRESHOLD,
            COMP.getPriorVotesForGovernor(msg.sender, block.number - 1)
        );

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(canPropose);

        uint256 requestId = Gateway.requestDecryption(
            cts,
            this.callbackInitiateProposal.selector,
            0,
            block.timestamp + 100,
            false
        );

        _requestIdToProposalId[requestId] = thisProposalId;

        return thisProposalId;
    }

    /**
     * @notice            Queue a new proposal.
     * @dev               It can be done only if the proposal is adopted.
     * @param proposalId  Proposal id.
     */
    function queue(uint256 proposalId) external {
        Proposal memory proposal = _proposals[proposalId];

        if (proposal.state != ProposalState.Succeeded) {
            revert ProposalStateInvalid();
        }

        uint256 eta = block.timestamp + TIMELOCK.delay();

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
        }

        _proposals[proposalId].eta = eta;
        _proposals[proposalId].state = ProposalState.Queued;

        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @notice            Request the vote results to be decrypted.
     * @param proposalId  Proposal id.
     */
    function requestVoteDecryption(uint256 proposalId) external {
        if (_proposals[proposalId].state != ProposalState.Active) {
            revert ProposalStateInvalid();
        }

        if (_proposals[proposalId].endBlock >= block.number) {
            revert ProposalStateStillActive();
        }

        uint256[] memory cts = new uint256[](2);
        cts[0] = Gateway.toUint256(_proposals[proposalId].forVotes);
        cts[1] = Gateway.toUint256(_proposals[proposalId].againstVotes);

        uint256 requestId = Gateway.requestDecryption(
            cts,
            this.callbackVoteDecryption.selector,
            0,
            block.timestamp + 100,
            false
        );

        _requestIdToProposalId[requestId] = proposalId;
        _proposals[proposalId].state = ProposalState.PendingResults;
    }

    /**
     * @dev                 Only callable by the gateway.
     * @param requestId     Request id (from the Gateway)
     * @param canInitiate   Whether the proposal can be initiated.
     */
    function callbackInitiateProposal(uint256 requestId, bool canInitiate) public onlyGateway {
        uint256 proposalId = _requestIdToProposalId[requestId];

        if (canInitiate) {
            _proposals[proposalId].state = ProposalState.Active;
            emit ProposalActive(proposalId);
        } else {
            _proposals[proposalId].state = ProposalState.Rejected;
            emit ProposalRejected(proposalId);
        }
    }

    /**
     * @dev                         Only callable by the gateway.
     * @param forVotesDecrypted     For votes.
     * @param againstVotesDecrypted Against votes.
     */
    function callbackVoteDecryption(
        uint256 requestId,
        uint256 forVotesDecrypted,
        uint256 againstVotesDecrypted
    ) public onlyGateway {
        uint256 proposalId = _requestIdToProposalId[requestId];

        /// @dev It is safe to downcast since the original values were euint64.
        _proposals[proposalId].forVotesDecrypted = uint64(forVotesDecrypted);
        _proposals[proposalId].againstVotesDecrypted = uint64(againstVotesDecrypted);

        if (forVotesDecrypted > againstVotesDecrypted && forVotesDecrypted >= QUORUM_VOTES) {
            _proposals[proposalId].state = ProposalState.Succeeded;
            emit ProposalSucceeded(proposalId);
        } else {
            _proposals[proposalId].state = ProposalState.Defeated;
            emit ProposalDefeated(proposalId);
        }
    }

    /**
     * @dev Only callable by `owner`.
     */
    function acceptTimelockAdmin() external onlyOwner {
        TIMELOCK.acceptAdmin();
    }

    /**
     * @dev                   Only callable by `owner`.
     * @param newPendingAdmin Address of the new pending admin for the timelock.
     * @param eta             Eta for executing the transaction in the timelock.
     */
    function executeSetTimelockPendingAdmin(address newPendingAdmin, uint256 eta) external onlyOwner {
        TIMELOCK.executeTransaction(address(TIMELOCK), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }

    /**
     * @dev                   Only callable by `owner`.
     * @param newPendingAdmin Address of the new pending admin for the timelock.
     * @param eta             Eta for queuing the transaction in the timelock.
     */
    function queueSetTimelockPendingAdmin(address newPendingAdmin, uint256 eta) external onlyOwner {
        TIMELOCK.queueTransaction(address(TIMELOCK), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }

    /**
     * @notice                  Returns proposal information for a proposal id.
     * @dev                     It returns decrypted `forVotes`/`againstVotes`.
     *                          These are only available after the decryption.
     * @param proposalId        Proposal id.
     * @return proposalInfo     Proposal information.
     */
    function getProposalInfo(uint256 proposalId) external view returns (ProposalInfo memory proposalInfo) {
        Proposal memory proposal = _proposals[proposalId];
        proposalInfo.proposer = proposal.proposer;
        proposalInfo.state = proposal.state;
        proposalInfo.eta = proposal.eta;
        proposalInfo.targets = proposal.targets;
        proposalInfo.values = proposal.values;
        proposalInfo.signatures = proposal.signatures;
        proposalInfo.calldatas = proposal.calldatas;
        proposalInfo.startBlock = proposal.startBlock;
        proposalInfo.endBlock = proposal.endBlock;
        proposalInfo.forVotes = proposal.forVotesDecrypted;
        proposalInfo.againstVotes = proposal.againstVotesDecrypted;

        // The state is adjusted but not closed.
        if (
            (proposalInfo.state == ProposalState.Queued) &&
            (block.timestamp > proposalInfo.eta + TIMELOCK.GRACE_PERIOD())
        ) {
            proposalInfo.state = ProposalState.Expired;
        }
    }

    /**
     * @notice              Returns the vote receipt information for the account for a proposal id.
     * @param proposalId    Proposal id.
     * @param account       Account address.
     * @return hasVoted     Whether the account has voted.
     * @return support      The support for the account (true ==> vote for, false ==> vote against).
     * @return votes        The number of votes cast.
     */
    function getReceipt(uint256 proposalId, address account) external view returns (bool, ebool, euint64) {
        Receipt memory receipt = _accountReceiptForProposalId[proposalId][account];
        return (receipt.hasVoted, receipt.support, receipt.votes);
    }

    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        if (TIMELOCK.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta)))) {
            revert ProposalActionsAlreadyQueued();
        }

        TIMELOCK.queueTransaction(target, value, signature, data, eta);
    }

    function _castVote(address voter, uint256 proposalId, ebool support) internal {
        Proposal storage proposal = _proposals[proposalId];

        if (proposal.state != ProposalState.Active) {
            revert ProposalStateInvalid();
        }

        if (block.number > proposal.endBlock) {
            revert ProposalStateNotActive();
        }

        Receipt storage receipt = _accountReceiptForProposalId[proposalId][voter];

        if (receipt.hasVoted) {
            revert VoterHasAlreadyVoted();
        }

        euint64 votes = COMP.getPriorVotesForGovernor(voter, proposal.startBlock);
        proposal.forVotes = TFHE.select(support, TFHE.add(proposal.forVotes, votes), proposal.forVotes);
        proposal.againstVotes = TFHE.select(support, proposal.againstVotes, TFHE.add(proposal.againstVotes, votes));

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        TFHE.allowThis(proposal.forVotes);
        TFHE.allowThis(proposal.againstVotes);
        TFHE.allowThis(receipt.support);
        TFHE.allowThis(receipt.votes);
        TFHE.allow(receipt.support, msg.sender);
        TFHE.allow(receipt.votes, msg.sender);

        // `support` and `votes` are encrypted values, no need to include them in the event.
        emit VoteCast(voter, proposalId);
    }
}
