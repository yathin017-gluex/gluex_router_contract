// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {EthReceiver} from "./utils/EthReceiver.sol";
import {Interaction} from "./base/RouterStructs.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./lib/SafeERC20.sol";

/**
 * @title GluexRouter
 * @notice A versatile router contract that enables the execution of on-chain interactions using the `IExecutor` interface.
 * @dev This contract provides functionality for routing tokens through various interactions, collecting routing fees,
 *      and enforcing strict slippage and routing rules for optimal security and usability.
 */
contract GluexRouter is EthReceiver {
    using SafeERC20 for IERC20;

    // Errors
    error InsufficientBalance();
    error NativeTransferFailed();
    error OnlyGlueTreasury();
    error ZeroAddress();
    error NegativeSlippageLimit();
    error RoutingFeeTooHigh();
    error RoutingFeeTooLow();
    error PartnerSurplusShareTooHigh();
    error ProtocolSurplusShareTooLow();
    error PartnerSlippageShareTooHigh();
    error ProtocolSlippageShareTooLow();
    error InvalidSlippage();
    error SlippageLimitTooLarge();
    error InvalidNativeTokenInputAmount();
    error MaxFeeLimitExceeded();
    error MinFeeLimitExceeded();
    error MinFeeTooHigh();

    // Events
    /**
     * @notice Emitted when a routing operation is completed.
     * @param uniquePID The unique identifier for the partner.
     * @param userAddress The address of the user who initiated the route.
     * @param outputReceiver The address of the receiver of the output token.
     * @param inputToken The ERC20 token used as input.
     * @param inputAmount The amount of input token used for routing.
     * @param outputToken The ERC20 token received as output.
     * @param finalOutputAmount The actual output amount received after routing.
     * @param partnerFee The fee charged for the partner.
     * @param routingFee The fee charged for the routing operation.
     * @param partnerShare The share of surplus and slippage given to the partner.
     * @param protocolShare The share of surplus and slippage given to the GlueX protocol.
     */
    event Routed(
        bytes32 indexed uniquePID,
        address indexed userAddress,
        address outputReceiver,
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 finalOutputAmount,
        uint256 partnerFee,
        uint256 routingFee,
        uint256 partnerShare,
        uint256 protocolShare
    );

    // DataTypes
    /**
     * @dev A generic structure defining the parameters for a route.
     */
    struct RouteDescription {
        IERC20 inputToken; // Token used as input for the route
        IERC20 outputToken; // Token received as output from the route
        address payable inputReceiver; // Address to receive the input token
        address payable outputReceiver; // Address to receive the output token
        address payable partnerAddress; // Address of the partner receiving surplus share
        uint256 inputAmount; // Amount of input token
        uint256 outputAmount; // Optimizer output amount
        uint256 partnerFee; // Fee charged by the partner
        uint256 routingFee; // Fee charged for routing operation
        uint256 partnerSurplusShare; // Percentage (in bps) of surplus shared with the partner
        uint256 protocolSurplusShare; // Percentage (in bps) of surplus shared with GlueX
        uint256 partnerSlippageShare; // Percentage (in bps) of slippage shared with the partner
        uint256 protocolSlippageShare; // Percentage (in bps) of slippage shared with GlueX
        uint256 effectiveOutputAmount; // Effective output amount for the user
        uint256 minOutputAmount; // Minimum acceptable output amount
        bool isPermit2; // Whether to use Permit2 for token transfers
        bytes32 uniquePID; // Unique identifier for the partner
    }

    // Constants
    uint256 public _RAW_CALL_GAS_LIMIT = 5500;
    uint256 public _MAX_FEE = 15; // 15 bps (0.15%)
    uint256 public _MIN_FEE = 0; // 0 bps (0.00%)
    uint256 public _MAX_PARTNER_SURPLUS_SHARE_LIMIT = 5000; // 50% (5000 bps)
    uint256 public _MAX_PARTNER_SLIPPAGE_SHARE_LIMIT = 3300; // 33% (3300 bps)
    uint256 public _MIN_PROTOCOL_SURPLUS_SHARE_LIMIT = 5000; // 50% (5000 bps)
    uint256 public _MIN_PROTOCOL_SLIPPAGE_SHARE_LIMIT = 3000; // 30% (3000 bps)

    // State Variables
    address public immutable _nativeToken; // Address of the native token (e.g., Ether on Ethereum)
    address internal immutable _gluexTreasury; // Address of the GlueX treasury contract

    /**
     * @dev Initializes the contract with the treasury address and native token address.
     * @param gluexTreasury The address of the Glue treasury contract.
     * @param nativeToken The address of the native token.
     */
    constructor(address gluexTreasury, address nativeToken) {
        // Ensure the addresses are not zero
        checkZeroAddress(gluexTreasury);

        _gluexTreasury = gluexTreasury;
        _nativeToken = nativeToken;
    }

    /**
     * @dev Modifier to restrict access to treasury-only functions.
     */
    modifier onlyTreasury() {
        checkTreasury();
        _;
    }

    /**
     * @notice Verifies the caller is the Glue treasury.
     * @dev Reverts with `OnlyGlueTreasury` if the caller is not the treasury.
     */
    function checkTreasury() internal view {
        if (msg.sender != _gluexTreasury) revert OnlyGlueTreasury();
    }

    /**
     * @notice Verifies the given address is not zero.
     * @param addr The address to verify.
     * @dev Reverts with `ZeroAddress` if the address is zero.
     */
    function checkZeroAddress(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Collects routing fees from specified tokens and transfers them to the given receiver.
     * @param feeTokens An array of ERC20 tokens from which fees will be collected.
     * @param receiver The address where collected fees will be transferred.
     */
    function collectFees(IERC20[] memory feeTokens, address payable receiver)
        external
        onlyTreasury
    {
        // Ensure the receiver address is valid
        checkZeroAddress(receiver);

        // Collect fees for each token
        uint256 len = feeTokens.length;
        for (uint256 i = 0; i < len; ) {
            uint256 feeBalance = uniBalanceOf(feeTokens[i], address(this));
            uniTransfer(feeTokens[i], receiver, feeBalance);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Executes a route using the specified executor and interactions.
     * @param executor The executor contract that performs the interactions.
     * @param desc The route description containing input, output, and fee details.
     * @param interactions The interactions encoded for execution by the executor.
     * @return finalOutputAmount The final amount of output token received.
     * @dev Ensures strict validation of slippage, routing fees, and input/output parameters.
     */
    function swap(
        IExecutor executor,
        RouteDescription calldata desc,
        Interaction[] calldata interactions
    ) external payable returns (uint256 finalOutputAmount) {

        // Validate the route description
        validateSwap(desc);

        // Token transfer validation
        if (address(desc.inputToken) == _nativeToken) {
            if (msg.value != desc.inputAmount) revert InvalidNativeTokenInputAmount();
        } else {
            if (msg.value != 0) revert InvalidNativeTokenInputAmount();
            desc.inputToken.safeTransferFromUniversal(
                msg.sender,
                desc.inputReceiver,
                desc.inputAmount,
                desc.isPermit2
            );
        }

        // Execute the interactions using executor
        finalOutputAmount = executeInteractions(
            desc,
            executor,
            interactions
        );

        // Calculate final output amount
        uint256 partnerFee = desc.partnerFee;
        uint256 routingFee = 0;
        if (desc.routingFee != 0) {
            if (finalOutputAmount > desc.effectiveOutputAmount + desc.routingFee) {
                finalOutputAmount = finalOutputAmount - desc.routingFee;
                routingFee = desc.routingFee;
            } else if (finalOutputAmount > desc.effectiveOutputAmount) {
                routingFee = finalOutputAmount - desc.effectiveOutputAmount;
                finalOutputAmount = desc.effectiveOutputAmount;
            } else {
                finalOutputAmount = finalOutputAmount;
            }
        }

        // Surplus and Slippage calculation
        uint256 surplus = 0;
        uint256 slippage = 0;
        if (finalOutputAmount >= desc.outputAmount && desc.outputAmount >= desc.effectiveOutputAmount) {
            surplus = desc.outputAmount - desc.effectiveOutputAmount;
            slippage = finalOutputAmount - desc.effectiveOutputAmount;
        } else if (desc.outputAmount > finalOutputAmount && finalOutputAmount > desc.effectiveOutputAmount) {
            surplus = finalOutputAmount - desc.effectiveOutputAmount;
            slippage = 0;
        } else {
            surplus = 0;
            slippage = 0;
        }

        uint256 partnerShare = 0;
        uint256 protocolShare = 0;
        if (surplus != 0 || slippage != 0) {
            // Calculate and transfer partner surplus
            uint256 partnerSurplus = (surplus * desc.partnerSurplusShare) / 10000;
            uint256 partnerSlippage = (slippage * desc.partnerSlippageShare) / 10000;
            partnerShare = partnerSurplus + partnerSlippage;

            // Calculate and transfer routing surplus
            uint256 protocolSurplus = surplus - partnerSurplus;
            uint256 protocolSlippage = (slippage * desc.protocolSlippageShare) / 10000;
            protocolShare = protocolSurplus + protocolSlippage;

            finalOutputAmount -= (partnerShare + protocolShare);

            if (partnerShare != 0) {
                if (desc.partnerAddress != address(0)) {
                    uniTransfer(
                        desc.outputToken,
                        desc.partnerAddress,
                        partnerShare
                    );
                } else {
                    protocolShare += partnerShare; // If no partner address, add to protocol share
                }
            }

            uniTransfer(
                desc.outputToken,
                payable(_gluexTreasury),
                protocolShare
            );
        }

        // Ensure final output amount meets the minimum required
        if (finalOutputAmount < desc.minOutputAmount) revert NegativeSlippageLimit();

        // Transfer the final output amount to the output receiver
        uniTransfer(
            desc.outputToken,
            desc.outputReceiver,
            finalOutputAmount
        );

        emit Routed(
            desc.uniquePID,
            msg.sender,
            desc.outputReceiver,
            desc.inputToken,
            desc.inputAmount,
            desc.outputToken,
            finalOutputAmount,
            partnerFee,
            routingFee,
            partnerShare,
            protocolShare
        );
    }

    /**
     * @notice Validates the parameters of a swap operation.
     * @param desc The route description containing swap details.
     * @dev Ensures that routing fees, partner surplus shares, and slippage limits are within acceptable ranges.
     */
    function validateSwap(
        RouteDescription calldata desc
    ) internal view {
        // Validate routing fee
        if (desc.routingFee > (desc.outputAmount * _MAX_FEE) / 10000) revert RoutingFeeTooHigh();
        if (desc.routingFee < (desc.outputAmount * _MIN_FEE) / 10000) revert RoutingFeeTooLow();

        // Validate surplus sharing
        if (desc.partnerSurplusShare > _MAX_PARTNER_SURPLUS_SHARE_LIMIT) revert PartnerSurplusShareTooHigh();
        if (desc.protocolSurplusShare < _MIN_PROTOCOL_SURPLUS_SHARE_LIMIT) revert ProtocolSurplusShareTooLow();

        // Validate slippage sharing
        if (desc.partnerSlippageShare > _MAX_PARTNER_SLIPPAGE_SHARE_LIMIT) revert PartnerSlippageShareTooHigh();
        if (desc.protocolSlippageShare < _MIN_PROTOCOL_SLIPPAGE_SHARE_LIMIT) revert ProtocolSlippageShareTooLow();

        // Validate non-zero addresses
        checkZeroAddress(desc.inputReceiver);
        checkZeroAddress(desc.outputReceiver);

        // Validate route parameters
        if (desc.minOutputAmount == 0) revert InvalidSlippage();
        if (desc.minOutputAmount > desc.outputAmount) revert SlippageLimitTooLarge();
    }

    /**
     * @notice Executes the interactions defined in the route description using the specified executor.
     * @param desc The route description containing input, output, and interaction details.
     * @param executor The executor contract that will perform the interactions.
     * @param interactions The interactions to be executed.
     * @return finalOutputAmount The final amount of output token received after executing the interactions.
     */
    function executeInteractions(
        RouteDescription calldata desc,
        IExecutor executor,
        Interaction[] calldata interactions
    ) internal returns (uint256 finalOutputAmount) {
        // Execute interactions through the executor
        IERC20 outputToken = desc.outputToken;
        uint256 outputBalanceBefore = uniBalanceOf(outputToken, address(this));
        executor.executeRoute{value: msg.value}(
            interactions,
            desc.outputToken
        );
        uint256 outputBalanceAfter = uniBalanceOf(outputToken, address(this));

        finalOutputAmount = outputBalanceAfter - outputBalanceBefore;
    }

    /**
     * @notice Retrieves the balance of a specified token for a given account.
     * @param token The ERC20 token to check.
     * @param account The account address to query the balance for.
     * @return The balance of the token for the account.
     */
    function uniBalanceOf(IERC20 token, address account)
        internal
        view
        returns (uint256)
    {
        if (address(token) == _nativeToken) {
            uint256 contractBalance;
            assembly {
                contractBalance := balance(account)
            }
            return contractBalance;
        } else {
            return token.balanceOf(account);
        }
    }

    /**
     * @notice Transfers a specified amount of a token to a given address.
     * @param token The ERC20 token to transfer.
     * @param to The address to transfer the token to.
     * @param amount The amount of the token to transfer.
     * @dev Handles both native token and ERC20 transfers.
     */
    function uniTransfer(
        IERC20 token,
        address payable to,
        uint256 amount
    ) internal {
        if (amount != 0) {
            if (address(token) == _nativeToken) {
                uint256 contractBalance;
                assembly {
                    contractBalance := selfbalance()
                }
                if (contractBalance < amount) revert InsufficientBalance();
                (bool success, ) = to.call{
                    value: amount,
                    gas: _RAW_CALL_GAS_LIMIT
                }("");
                if (!success) revert NativeTransferFailed();
            } else {
                token.safeTransfer(to, amount);
            }
        } else {
            revert InsufficientBalance();
        }
    }

    /**
     * @notice Updates the gas limit for raw calls made by the contract.
     * @param gasLimit The new gas limit to be set.
     * @dev This function is restricted to the treasury.
     */
    function setGasLimit(uint256 gasLimit) external onlyTreasury {
        _RAW_CALL_GAS_LIMIT = gasLimit;
    }

    /**
     * @notice Updates the maximum fee that can be charged by the contract.
     * @param maxFee The new maximum fee to be set.
     * @dev This function is restricted to the treasury.
     */
    function setMaxFee(uint256 maxFee) external onlyTreasury {
        if (maxFee > 10000) revert MaxFeeLimitExceeded();
        _MAX_FEE = maxFee;
    }

    /**
     * @notice Updates the minimum fee that can be charged by the contract.
     * @param minFee The new minimum fee to be set.
     * @dev This function is restricted to the treasury.
     */
    function setMinFee(uint256 minFee) external onlyTreasury {
        if (minFee > 10000) revert MinFeeLimitExceeded();
        if (minFee > _MAX_FEE) revert MinFeeTooHigh();
        _MIN_FEE = minFee;
    }

    /**
     * @notice Updates the partner surplus share limit.
     * @param partnerSurplusShareLimit The new limit for partner surplus share.
     * @dev This function is restricted to the treasury.
     */
    function setPartnerSurplusShareLimit(uint256 partnerSurplusShareLimit)
        external
        onlyTreasury
    {
        _MAX_PARTNER_SURPLUS_SHARE_LIMIT = partnerSurplusShareLimit;
    }

    /**
     * @notice Updates the partner slippage share limit.
     * @param partnerSlippageShareLimit The new limit for partner slippage share.
     * @dev This function is restricted to the treasury.
     */
    function setPartnerSlippageShareLimit(uint256 partnerSlippageShareLimit)
        external
        onlyTreasury
    {        
        _MAX_PARTNER_SLIPPAGE_SHARE_LIMIT = partnerSlippageShareLimit;
    }

    /**
     * @notice Updates the protocol surplus share limit.
     * @param protocolSurplusShareLimit The new limit for protocol surplus share.
     * @dev This function is restricted to the treasury.
     */
    function setProtocolSurplusShareLimit(uint256 protocolSurplusShareLimit)
        external
        onlyTreasury
    {
        _MIN_PROTOCOL_SURPLUS_SHARE_LIMIT = protocolSurplusShareLimit;
    }

    /**
     * @notice Updates the protocol slippage share limit.
     * @param protocolSlippageShareLimit The new limit for protocol slippage share.
     * @dev This function is restricted to the treasury.
     */
    function setProtocolSlippageShareLimit(uint256 protocolSlippageShareLimit)
        external
        onlyTreasury
    {
        _MIN_PROTOCOL_SLIPPAGE_SHARE_LIMIT = protocolSlippageShareLimit;
    }
    
}