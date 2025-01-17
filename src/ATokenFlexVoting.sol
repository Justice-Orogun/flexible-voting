// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// forgefmt: disable-start
import {AToken} from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import {MintableIncentivizedERC20} from "aave-v3-core/contracts/protocol/tokenization/base/MintableIncentivizedERC20.sol";
import {Errors} from "aave-v3-core/contracts/protocol/libraries/helpers/Errors.sol";
import {GPv2SafeERC20} from "aave-v3-core/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol";
import {IAToken} from "aave-v3-core/contracts/interfaces/IAToken.sol";
import {IAaveIncentivesController} from "aave-v3-core/contracts/interfaces/IAaveIncentivesController.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "openzeppelin-contracts/utils/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
// forgefmt: disable-end

/// @notice This is an extension of Aave V3's AToken contract which makes it possible for AToken
/// holders to still vote on governance proposals. This way, holders of governance tokens do not
/// have to choose between earning yield on Aave and voting. They can do both.
///
/// AToken holders are able to call `expressVote` to signal their preference on open governance
/// proposals. When they do so, this extension records that preference with weight proportional to
/// the users's AToken balance at the proposal snapshot.
///
/// At any point after voting preferences have been expressed, the AToken's public `castVote`
/// function may be called to roll up all internal voting records into a single delegated vote to
/// the Governor contract -- a vote which specifies the exact For/Abstain/Against totals expressed
/// by AToken holders. Votes can be rolled up and cast in this manner multiple times for a given
/// proposal.
///
/// This extension has the following requirements:
///   (a) the underlying token be a governance token
///   (b) the related governor contract supports flexible voting (see GovernorCountingFractional)
///
/// Participating in governance via AToken voting is completely optional. Users otherwise still
/// supply, borrow, and hold tokens with Aave as usual.
///
/// The original AToken that this contract extends is viewable here:
///
///   https://github.com/aave/aave-v3-core/blob/c38c6276/contracts/protocol/tokenization/AToken.sol
contract ATokenFlexVoting is AToken {
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.History;

  /// @notice The voting options corresponding to those used in the Governor.
  enum VoteType {
    Against,
    For,
    Abstain
  }

  /// @notice Data structure to store vote preferences expressed by depositors.
  struct ProposalVote {
    uint128 againstVotes;
    uint128 forVotes;
    uint128 abstainVotes;
  }

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private proposalVotersHasVoted;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @notice The governor contract associated with this governance token. It
  /// must be one that supports fractional voting, e.g. GovernorCountingFractional.
  IFractionalGovernor public immutable GOVERNOR;

  /// @notice Mapping from address to stored (not rebased) balance checkpoint history.
  mapping(address => Checkpoints.History) private balanceCheckpoints;

  /// @notice History of total stored (not rebased) balances.
  Checkpoints.History private totalDepositCheckpoints;

  /// @dev Constructor.
  /// @param _pool The address of the Pool contract
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(IPool _pool, address _governor) AToken(_pool) {
    GOVERNOR = IFractionalGovernor(_governor);
  }

  // forgefmt: disable-start
  //===========================================================================
  // BEGIN: Aave overrides
  //===========================================================================
  /// Note: this has been modified from Aave v3's AToken to delegate voting
  /// power to itself during initialization.
  ///
  /// @inheritdoc AToken
  function initialize(
    IPool initializingPool,
    address treasury,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 aTokenDecimals,
    string calldata aTokenName,
    string calldata aTokenSymbol,
    bytes calldata params
  ) public override initializer {
    AToken.initialize(
      initializingPool,
      treasury,
      underlyingAsset,
      incentivesController,
      aTokenDecimals,
      aTokenName,
      aTokenSymbol,
      params
    );

    selfDelegate();
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _burn(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._burn(account, amount);
    _checkpointRawBalanceOf(account);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() - amount);
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _mint(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._mint(account, amount);
    _checkpointRawBalanceOf(account);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() + amount);
  }

  /// @dev This has been modified from Aave v3's AToken contract to checkpoint raw balances
  /// accordingly.  Ideally we would have overriden `IncentivizedERC20._transfer` instead of
  /// `AToken._transfer` as we did for `_mint` and `_burn`, but that isn't possible here:
  /// `AToken._transfer` *already is* an override of `IncentivizedERC20._transfer`
  ///
  /// @inheritdoc AToken
  function _transfer(
    address from,
    address to,
    uint256 amount,
    bool validate
  ) internal virtual override {
    AToken._transfer(from, to, amount, validate);
    _checkpointRawBalanceOf(from);
    _checkpointRawBalanceOf(to);
  }
  //===========================================================================
  // END: Aave overrides
  //===========================================================================
  // forgefmt: disable-end

  // Self-delegation cannot be done in the constructor because the aToken is
  // just a proxy -- it won't share an address with the implementation (i.e.
  // this code). Instead we do it at the end of `initialize`. But even that won't
  // handle already-initialized aTokens. For those, we'll need to self-delegate
  // during the upgrade process. More details in these issues:
  // https://github.com/aave/aave-v3-core/pull/774
  // https://github.com/ScopeLift/flexible-voting/issues/16
  function selfDelegate() public {
    IVotingToken(GOVERNOR.token()).delegate(address(this));
  }

  /// @notice Allow a depositor to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    uint256 weight = getPastStoredBalance(msg.sender, GOVERNOR.proposalSnapshot(proposalId));
    require(weight > 0, "no weight");

    require(!proposalVotersHasVoted[proposalId][msg.sender], "already voted");
    proposalVotersHasVoted[proposalId][msg.sender] = true;

    if (support == uint8(VoteType.Against)) {
      proposalVotes[proposalId].againstVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.For)) {
      proposalVotes[proposalId].forVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.Abstain)) {
      proposalVotes[proposalId].abstainVotes += SafeCast.toUint128(weight);
    } else {
      revert("invalid support value, must be included in VoteType enum");
    }
  }

  /// @notice Causes this contract to cast a vote to the Governor for all of the
  /// accumulated votes expressed by users. Uses the sum of all raw (unrebased) balances
  /// to proportionally split its voting weight. Can be called by anyone. Can be called
  /// multiple times during the lifecycle of a given proposal.
  /// @param proposalId The ID of the proposal which the Pool will now vote on.
  function castVote(uint256 proposalId) external {
    ProposalVote storage _proposalVote = proposalVotes[proposalId];
    require(
      _proposalVote.forVotes + _proposalVote.againstVotes + _proposalVote.abstainVotes > 0,
      "no votes expressed"
    );
    uint256 _proposalSnapshotBlockNumber = GOVERNOR.proposalSnapshot(proposalId);

    // We use the snapshot of total raw balances to determine the weight with
    // which to vote. We do this for two reasons:
    //   (1) We cannot use the proposalVote numbers alone, since some people with
    //       balances at the snapshot might never express their preferences. If a
    //       large holder never expressed a preference, but this contract nevertheless
    //       cast votes to the governor with all of its weight, then other users may
    //       effectively have *increased* their voting weight because someone else
    //       didn't participate, which creates all kinds of bad incentives.
    //   (2) Other people might have already expressed their preferences on this
    //       proposal and had those preferences submitted to the governor by an
    //       earlier call to this function. The weight of those preferences
    //       should still be taken into consideration when determining how much
    //       weight to vote with this time.
    // Using the total raw balance to proportion votes in this way means that in
    // many circumstances this function will not cast votes with all of its
    // weight.
    uint256 _totalRawBalanceAtSnapshot = getPastTotalBalance(_proposalSnapshotBlockNumber);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _votingWeightAtSnapshot = IVotingToken(address(_underlyingAsset)).getPastVotes(
      address(this), _proposalSnapshotBlockNumber
    );

    //      forVotesRaw          forVoteWeight
    // --------------------- = ------------------
    //     totalRawBalance      totalVoteWeight
    //
    // forVoteWeight = forVotesRaw * totalVoteWeight / totalRawBalance
    uint128 _forVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.forVotes) / _totalRawBalanceAtSnapshot
    );
    uint128 _againstVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.againstVotes) / _totalRawBalanceAtSnapshot
    );
    uint128 _abstainVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.abstainVotes) / _totalRawBalanceAtSnapshot
    );

    // This param is ignored by the governor when voting with fractional
    // weights. It makes no difference what vote type this is.
    uint8 unusedSupportParam = uint8(VoteType.Abstain);

    // Clear the stored votes so that we don't double-cast them.
    delete proposalVotes[proposalId];

    bytes memory fractionalizedVotes =
      abi.encodePacked(_againstVotesToCast, _forVotesToCast, _abstainVotesToCast);
    GOVERNOR.castVoteWithReasonAndParams(
      proposalId,
      unusedSupportParam,
      "rolled-up vote from aToken holders", // Reason string.
      fractionalizedVotes
    );
  }

  /// @notice Returns the _user's current balance in storage.
  function _rawBalanceOf(address _user) internal view returns (uint256) {
    return _userState[_user].balance;
  }

  /// @notice Checkpoints the _user's current raw balance.
  function _checkpointRawBalanceOf(address _user) internal {
    balanceCheckpoints[_user].push(_rawBalanceOf(_user));
  }

  /// @notice Returns the _user's balance in storage at the _blockNumber.
  /// @param _user The account that's historical balance will be looked up.
  /// @param _blockNumber The block at which to lookup the _user's balance.
  function getPastStoredBalance(address _user, uint256 _blockNumber) public view returns (uint256) {
    return balanceCheckpoints[_user].getAtProbablyRecentBlock(_blockNumber);
  }

  /// @notice Returns the total stored balance of all users at _blockNumber.
  /// @param _blockNumber The block at which to lookup the total stored balance.
  function getPastTotalBalance(uint256 _blockNumber) public view returns (uint256) {
    return totalDepositCheckpoints.getAtProbablyRecentBlock(_blockNumber);
  }
}
