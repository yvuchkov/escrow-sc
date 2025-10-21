// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MultiPartyEscrow is ReentrancyGuard, Pausable, Ownable {

    error MultiPartyEscrow__FeeTooHigh();
    error MultiPartyEscrow__InvalidSeller();
    error MultiPartyEscrow__InvalidArbiter();
    error MultiPartyEscrow__SellerCannotBeBuyer();
    error MultiPartyEscrow__InvalidDeadline();
    error MultiPartyEscrow__OnlyBuyerCanFund();
    error MultiPartyEscrow__InvalidStatus();
    error MultiPartyEscrow__AmountMustBeGreaterThanZero();
    error MultiPartyEscrow__OnlySellerCanConfirm();
    error MultiPartyEscrow__DeadlinePassed();
    error MultiPartyEscrow__OnlyBuyerCanRelease();
    error MultiPartyEscrow__TransferFailed();

    enum EscrowStatus {
        Created,
        Funded,
        Delivered,
        Completed,
        Disputed,
        Refunded,
        Cancelled
    }

    struct Escrow {
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 platformFee;
        uint256 createdAt;
        uint256 deliveryDeadline;
        EscrowStatus status;
        bool sellerConfirmedDelivery;
        bool buyerReleasedPayment;
    }

    uint256 public escrowCounter;
    uint256 public platformFeePercentage;
    uint256 public constant MAX_FEE_PERCENTAGE = 1000;
    uint256 public constant FEE_DENOMINATOR = 10000;

    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256) public accumulatedFees;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount,
        uint256 deliveryDeadline
    );

    event EscrowFunded(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 amount,
        uint256 platformFee
    );

    event DeliveryConfirmed(
        uint256 indexed escrowId,
        address indexed seller
    );

    event PaymentReleased(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount
    );

    event EscrowCompleted(
        uint256 indexed escrowId,
        uint256 sellerAmount,
        uint256 platformFee
    );

    constructor(uint256 _platformFeePercentage) Ownable(msg.sender) {
        if (_platformFeePercentage > MAX_FEE_PERCENTAGE) {
            revert MultiPartyEscrow__FeeTooHigh();
        }
        platformFeePercentage = _platformFeePercentage;
    }

    /**
     * @dev Pauses all escrow operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses all escrow operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Creates a new escrow agreement
     * @param _seller Address of the seller
     * @param _arbiter Address of the arbiter/mediator
     * @param _deliveryDeadline Unix timestamp for delivery deadline
     */
    function createEscrow(
        address _seller,
        address _arbiter,
        uint256 _deliveryDeadline
    ) external whenNotPaused returns (uint256) {
        if (_seller == address(0)) {
            revert MultiPartyEscrow__InvalidSeller();
        }
        if (_arbiter == address(0)) {
            revert MultiPartyEscrow__InvalidArbiter();
        }
        if (_seller == msg.sender) {
            revert MultiPartyEscrow__SellerCannotBeBuyer();
        }
        if (_arbiter == msg.sender || _arbiter == _seller) {
            revert MultiPartyEscrow__InvalidArbiter();
        }
        if (_deliveryDeadline <= block.timestamp) {
            revert MultiPartyEscrow__InvalidDeadline();
        }

        uint256 escrowId = escrowCounter++;

        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: _seller,
            arbiter: _arbiter,
            amount: 0,
            platformFee: 0,
            createdAt: block.timestamp,
            deliveryDeadline: _deliveryDeadline,
            status: EscrowStatus.Created,
            sellerConfirmedDelivery: false,
            buyerReleasedPayment: false
        });

        emit EscrowCreated(
            escrowId,
            msg.sender,
            _seller,
            _arbiter,
            0,
            _deliveryDeadline
        );

        return escrowId;
    }

    /**
     * @dev Funds an existing escrow with ETH
     * @param _escrowId The ID of the escrow to fund
     */
    function fundEscrow(uint256 _escrowId) external payable whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[_escrowId];

        if (escrow.buyer != msg.sender) {
            revert MultiPartyEscrow__OnlyBuyerCanFund();
        }
        if (escrow.status != EscrowStatus.Created) {
            revert MultiPartyEscrow__InvalidStatus();
        }
        if (msg.value == 0) {
            revert MultiPartyEscrow__AmountMustBeGreaterThanZero();
        }

        uint256 platformFee = (msg.value * platformFeePercentage) / FEE_DENOMINATOR;
        uint256 escrowAmount = msg.value - platformFee;

        escrow.amount = escrowAmount;
        escrow.platformFee = platformFee;
        escrow.status = EscrowStatus.Funded;

        accumulatedFees[owner()] += platformFee;

        emit EscrowFunded(_escrowId, msg.sender, escrowAmount, platformFee);
    }

    /**
     * @dev Seller confirms delivery of goods/service
     * @param _escrowId The ID of the escrow
     */
    function confirmDelivery(uint256 _escrowId) external whenNotPaused {
        Escrow storage escrow = escrows[_escrowId];

        if (escrow.seller != msg.sender) {
            revert MultiPartyEscrow__OnlySellerCanConfirm();
        }
        if (escrow.status != EscrowStatus.Funded) {
            revert MultiPartyEscrow__InvalidStatus();
        }
        if (block.timestamp > escrow.deliveryDeadline) {
            revert MultiPartyEscrow__DeadlinePassed();
        }

        escrow.sellerConfirmedDelivery = true;
        escrow.status = EscrowStatus.Delivered;

        emit DeliveryConfirmed(_escrowId, msg.sender);
    }

    /**
     * @dev Buyer releases payment to seller after delivery confirmation
     * @param _escrowId The ID of the escrow
     */
    function releasePayment(uint256 _escrowId) external whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[_escrowId];

        if (escrow.buyer != msg.sender) {
            revert MultiPartyEscrow__OnlyBuyerCanRelease();
        }
        if (escrow.status != EscrowStatus.Delivered && escrow.status != EscrowStatus.Funded) {
            revert MultiPartyEscrow__InvalidStatus();
        }

        escrow.buyerReleasedPayment = true;
        escrow.status = EscrowStatus.Completed;

        uint256 sellerAmount = escrow.amount;

        (bool success, ) = escrow.seller.call{value: sellerAmount}("");
        if (!success) {
            revert MultiPartyEscrow__TransferFailed();
        }

        emit PaymentReleased(_escrowId, msg.sender, escrow.seller, sellerAmount);
        emit EscrowCompleted(_escrowId, sellerAmount, escrow.platformFee);
    }
}
