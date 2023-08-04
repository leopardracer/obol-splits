// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Clone} from "solady/utils/Clone.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title OptimisticWithdrawalRecipient
/// @author Obol
/// @notice A maximally-composable contract that distributes payments
/// based on threshold to it's recipients
/// @dev Only one token can be waterfall'd for a given deployment. There is a
/// recovery method for non-target tokens sent by accident.
/// Target ERC20s with very large decimals may overflow & cause issues.
/// This contract uses token = address(0) to refer to ETH.
contract OptimisticWithdrawalRecipient is Clone {
    /// -----------------------------------------------------------------------
    /// libraries
    /// -----------------------------------------------------------------------

    using SafeTransferLib for address;

    /// -----------------------------------------------------------------------
    /// errors
    /// -----------------------------------------------------------------------

    /// Invalid token recovery; cannot recover the OWRecipient token
    error InvalidTokenRecovery_OWRToken();

    /// Invalid token recovery recipient
    error InvalidTokenRecovery_InvalidRecipient();

    /// Invalid distribution
    error InvalidDistribution_TooLarge();

    /// -----------------------------------------------------------------------
    /// events
    /// -----------------------------------------------------------------------

    /// Emitted after each successful ETH transfer to proxy
    /// @param amount Amount of ETH received
    /// @dev embedded in & emitted from clone bytecode
    event ReceiveETH(uint256 amount);

    /// Emitted after funds are waterfall'd to recipients
    /// @param recipients Addresses receiving payouts
    /// @param payouts Amount of payout
    /// @param pullFlowFlag Flag for pushing funds to recipients or storing for pulling
    event WaterfallFunds(
        address[] recipients, uint256[] payouts, uint256 pullFlowFlag
    );

    /// Emitted after non-OWRecipient tokens are recovered to a recipient
    /// @param nonOWRecipientToken Recovered token (cannot be OptimisticWithdrawalRecipient token)
    /// @param recipient Address receiving recovered token
    /// @param amount Amount of recovered token
    event RecoverNonOWRecipientFunds(
        address nonOWRecipientToken, address recipient, uint256 amount
    );

    /// Emitted after funds withdrawn using pull flow
    /// @param account Account withdrawing funds for
    /// @param amount Amount withdrawn
    event Withdrawal(address account, uint256 amount);

    /// -----------------------------------------------------------------------
    /// storage
    /// -----------------------------------------------------------------------

    /// -----------------------------------------------------------------------
    /// storage - constants
    /// -----------------------------------------------------------------------

    address internal constant ETH_ADDRESS = address(0);

    uint256 internal constant PUSH = 0;
    uint256 internal constant PULL = 1;

    uint256 internal constant ONE_WORD = 32;
    uint256 internal constant THRESHOLD_BITS = 96;
    uint256 internal constant ADDRESS_BITS = 160;
    uint256 internal constant ADDRESS_BITMASK = uint256(~0 >> THRESHOLD_BITS);
    uint256 internal constant BALANCE_CLASSIFICATION_THRESHOLD = 16 ether;
    uint256 internal constant TRANCHE_SIZE = 2;
    uint256 internal constant PRINCIPAL_RECIPIENT_INDEX = 0;
    uint256 internal constant REWARD_RECIPIENT_INDEX = 1;

    /// -----------------------------------------------------------------------
    /// storage - cwia offsets
    /// -----------------------------------------------------------------------

    // token (address, 20 bytes), nonWaterfallRecipient (address, 20 bytes),
    // numTranches (uint64, 8 bytes), tranches (uint256[], numTranches * 32 bytes)

    // 0; first item
    uint256 internal constant TOKEN_OFFSET = 0;
    // 20 = token_offset (0) + token_size (address, 20 bytes)
    uint256 internal constant NON_WATERFALL_RECIPIENT_OFFSET = 20;
    // 40 = nonWaterfallRecipient_offset (20) + nonWaterfallRecipient_size (address, 20 bytes)
    // uint256 internal constant NUM_TRANCHES_OFFSET = 40;
    // 48 = numTranches_offset (40) + numTranches_size (uint64, 8 bytes)
    uint256 internal constant TRANCHES_OFFSET = 40;

    /// Address of ERC20 to waterfall (0x0 used for ETH)
    /// @dev equivalent to address public immutable token;
    function token() public pure returns (address) {
        return _getArgAddress(TOKEN_OFFSET);
    }

    /// Address to recover non-waterfall tokens to
    /// @dev equivalent to address public immutable nonWaterfallRecipient;
    function nonWaterfallRecipient() public pure returns (address) {
        return _getArgAddress(NON_WATERFALL_RECIPIENT_OFFSET);
    }

    /// Number of waterfall tranches
    /// @dev equivalent to uint64 internal immutable numTranches;
    /// clones-with-immutable-args limits uint256[] array length to uint64
    function numTranches() internal pure returns (uint256) {
        return uint256(TRANCHE_SIZE);
    }

    /// Get waterfall tranche `i`
    /// @dev emulates to uint256[] internal immutable tranche;
    function _getTranche(uint256 i) internal pure returns (uint256) {
        unchecked {
            // shouldn't overflow
            return _getArgUint256(TRANCHES_OFFSET + i * ONE_WORD);
        }
    }

    // /// Expected amount of ETH to be staked
    // /// @dev equivalent to uint256 internal immutable stakedAmount
    /// @TODO get from the first tranche
    // function principal() public pure returns(uint256) {
    //     return _getArgUint256(STAKE_ETHER_OFFSET);
    // }

    /// -----------------------------------------------------------------------
    /// storage - mutables
    /// -----------------------------------------------------------------------

    /// Amount of distributed OWRecipient token
    /// @dev ERC20s with very large decimals may overflow & cause issues
    uint128 public distributedFunds;

    /// Amount of active balance set aside for pulls
    /// @dev ERC20s with very large decimals may overflow & cause issues
    uint128 public fundsPendingWithdrawal;

    /// Amount of distributed OWRecipient token for first tranche
    /// @dev ERC20s with very large decimals may overflow & cause issues
    uint256 public claimedFirstTrancheFunds;

    /// Mapping to account balances for pulling
    mapping(address => uint256) internal pullBalances;

    /// -----------------------------------------------------------------------
    /// constructor
    /// -----------------------------------------------------------------------

    // solhint-disable-next-line no-empty-blocks
    /// clone implementation doesn't use constructor
    constructor() {}

    /// -----------------------------------------------------------------------
    /// functions
    /// -----------------------------------------------------------------------

    /// -----------------------------------------------------------------------
    /// functions - public & external
    /// -----------------------------------------------------------------------

    /// emit event when receiving ETH
    /// @dev implemented w/i clone bytecode
    /* receive() external payable { */
    /*     emit ReceiveETH(msg.value); */
    /* } */

    /// Waterfalls target token inside the contract to next-in-line recipients
    /// @dev pushes funds to recipients
    function waterfallFunds() external payable {
        _waterfallFunds(PUSH);
    }

    /// Waterfalls target token inside the contract to next-in-line recipients
    /// @dev backup recovery if any recipient tries to brick the OWRecipient for
    /// remaining recipients
    function waterfallFundsPull() external payable {
        _waterfallFunds(PULL);
    }

    /// Recover non-waterfall'd tokens to a recipient
    /// @param nonWaterfallToken Token to recover (cannot be OWRecipient token)
    /// @param recipient Address to receive recovered token
    function recoverNonWaterfallFunds(
        address nonWaterfallToken,
        address recipient
    ) external payable {
        /// checks

        // revert if caller tries to recover OWRecipient token
        if (nonWaterfallToken == token()) {
            revert InvalidTokenRecovery_OWRToken();
        }

        // if nonWaterfallRecipient is set, recipient must match it
        // else, recipient must be one of the waterfall's recipients

        address _nonWaterfallRecipient = nonWaterfallRecipient();
        if (_nonWaterfallRecipient == address(0)) {
            // ensure txn recipient is a valid waterfall recipient
            (address[] memory recipients,) = getTranches();
            bool validRecipient = false;
            uint256 _numTranches = numTranches();
            for (uint256 i; i < _numTranches;) {
                if (recipients[i] == recipient) {
                    validRecipient = true;
                    break;
                }
                unchecked {
                    // shouldn't overflow
                    ++i;
                }
            }
            if (!validRecipient) {
                revert InvalidTokenRecovery_InvalidRecipient();
            }
        } else if (recipient != _nonWaterfallRecipient) {
            revert InvalidTokenRecovery_InvalidRecipient();
        }

        /// effects

        /// interactions

        // recover non-target token
        uint256 amount;
        if (nonWaterfallToken == ETH_ADDRESS) {
            amount = address(this).balance;
            recipient.safeTransferETH(amount);
        } else {
            amount = ERC20(nonWaterfallToken).balanceOf(address(this));
            nonWaterfallToken.safeTransfer(recipient, amount);
        }

        emit RecoverNonOWRecipientFunds(nonWaterfallToken, recipient, amount);
    }

    /// Withdraw token balance for account `account`
    /// @param account Address to withdraw on behalf of
    function withdraw(address account) external {
        address _token = token();
        uint256 tokenAmount = pullBalances[account];
        unchecked {
            // shouldn't underflow; fundsPendingWithdrawal = sum(pullBalances)
            fundsPendingWithdrawal -= uint128(tokenAmount);
        }
        pullBalances[account] = 0;
        if (_token == ETH_ADDRESS) {
            account.safeTransferETH(tokenAmount);
        } else {
            _token.safeTransfer(account, tokenAmount);
        }

        emit Withdrawal(account, tokenAmount);
    }

    /// -----------------------------------------------------------------------
    /// functions - view & pure
    /// -----------------------------------------------------------------------

    /// Return unpacked tranches
    /// @return recipients Addresses to waterfall payments to
    /// @return threshold Absolute payment threshold for principal
    function getTranches()
        public
        pure
        returns (address[] memory recipients, uint256 threshold)
    {
        recipients = new address[](TRANCHE_SIZE);

        uint256 tranche = _getTranche(PRINCIPAL_RECIPIENT_INDEX);
        recipients[0] = address(uint160(tranche));
        threshold = tranche >> ADDRESS_BITS;

        // recipients has one more entry than thresholds
        recipients[1] = address(uint160(_getTranche(REWARD_RECIPIENT_INDEX)));
    }

    /// Returns the balance for account `account`
    /// @param account Account to return balance for
    /// @return Account's balance waterfall token
    function getPullBalance(address account) external view returns (uint256) {
        return pullBalances[account];
    }

    /// -----------------------------------------------------------------------
    /// functions - private & internal
    /// -----------------------------------------------------------------------


    /// 

    /// Waterfalls target token inside the contract to next-in-line recipients
    /// @dev can PUSH or PULL funds to recipients
    function _waterfallFunds(uint256 pullFlowFlag) internal {
        /// checks

        /// effects

        // load storage into memory
        // fetch the token we want to distribute
        address _token = token();
        // uint256 _principalIndex;
        // the amount of funds distributed so far
        uint256 _startingDistributedFunds = uint256(distributedFunds);
        uint256 _endingDistributedFunds;
        uint256 _fundsToBeDistributed;
        uint256 _claimedFirstTrancheFunds = uint256(claimedFirstTrancheFunds);
        uint256 _memoryFundsPendingWithdrawal = uint256(fundsPendingWithdrawal);
        unchecked {
            // shouldn't overflow
            _endingDistributedFunds = _startingDistributedFunds
            // fundsPendingWithdrawal is always <= _startingDistributedFunds
            - _memoryFundsPendingWithdrawal
            // recognizes 0x0 as ETH
            // shouldn't need to worry about re-entrancy from ERC20 view fn
            + (
                _token == ETH_ADDRESS
                    ? address(this).balance
                    : ERC20(_token).balanceOf(address(this))
            );
            _fundsToBeDistributed = _endingDistributedFunds - _startingDistributedFunds;
        }

        (address[] memory recipients, uint256 threshold) =
            getTranches();

        // determine which tranche is getting paid based on funds to be distributed
        // 0 = first tranche
        // 1 = second tranche

        // construct the payout arrays
        uint256 _payoutsLength = numTranches();
        uint256[] memory _payouts = new uint256[](_payoutsLength);

        unchecked {
            // uint256 _rewardIndex = 1;
            // _claimedFirstTrancheFunds should always be <= threshold
            uint256 firstTrancheRemaining = threshold - _claimedFirstTrancheFunds;
            
            if (_fundsToBeDistributed >= BALANCE_CLASSIFICATION_THRESHOLD && firstTrancheRemaining > 0) {
                if (_fundsToBeDistributed > firstTrancheRemaining) {
                    // this means there is reward part of the funds to be distributed
                    _payouts[PRINCIPAL_RECIPIENT_INDEX] = firstTrancheRemaining;
                    // shouldn't underflow
                    _payouts[REWARD_RECIPIENT_INDEX] = _fundsToBeDistributed - firstTrancheRemaining;
                } else {
                    // this means there is no reward part of the funds to be distributed
                    _payouts[PRINCIPAL_RECIPIENT_INDEX] = _fundsToBeDistributed;
                }
            } else {
                _payouts[REWARD_RECIPIENT_INDEX] = _fundsToBeDistributed;
            }
        }

        {
            if (_endingDistributedFunds > type(uint128).max) {
                revert InvalidDistribution_TooLarge();
            }
            // Write to storage
            distributedFunds = uint128(_endingDistributedFunds);
            // the principal value
            claimedFirstTrancheFunds += _payouts[PRINCIPAL_RECIPIENT_INDEX];
        }

        /// interactions

        // pay outs
        // earlier tranche recipients may try to re-enter but will cause fn to revert
        // when later external calls fail (bc balance is emptied early)
        for (uint256 i; i < _payoutsLength;) {
            if (_payouts[i] > 0) {
                if (pullFlowFlag == PULL) {
                    pullBalances[recipients[i]] += _payouts[i];
                    _memoryFundsPendingWithdrawal += _payouts[i];
                } else if (_token == ETH_ADDRESS) {
                    (recipients[i]).safeTransferETH(_payouts[i]);
                } else {
                    _token.safeTransfer(recipients[i], _payouts[i]);
                }
            }
            unchecked {
                // shouldn't overflow
                ++i;
            }
        }

        if (pullFlowFlag == PULL) {
            // Write to storage
            fundsPendingWithdrawal = uint128(_memoryFundsPendingWithdrawal);
        }

        emit WaterfallFunds(recipients, _payouts, pullFlowFlag);
    }
}