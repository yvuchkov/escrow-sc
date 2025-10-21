// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultiPartyEscrow.sol";

contract MultiPartyEscrowTest is Test {
    MultiPartyEscrow public escrow;

    address public owner;
    address public buyer;
    address public seller;
    address public arbiter;

    uint256 public constant PLATFORM_FEE = 250;
    uint256 public constant ESCROW_AMOUNT = 1 ether;
    uint256 public constant DELIVERY_DEADLINE = 7 days;

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

    function setUp() public {
        owner = address(this);
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        arbiter = makeAddr("arbiter");

        escrow = new MultiPartyEscrow(PLATFORM_FEE);

        vm.deal(buyer, 10 ether);
        vm.deal(seller, 10 ether);
    }

    function testConstructor() public {
        assertEq(escrow.platformFeePercentage(), PLATFORM_FEE);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.escrowCounter(), 0);
    }

    function testConstructorWithHighFee() public {
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__FeeTooHigh.selector);
        new MultiPartyEscrow(1001);
    }

    function testCreateEscrow() public {
        vm.startPrank(buyer);

        uint256 deadline = block.timestamp + DELIVERY_DEADLINE;

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(0, buyer, seller, arbiter, 0, deadline);

        uint256 escrowId = escrow.createEscrow(seller, arbiter, deadline);

        assertEq(escrowId, 0);

        (
            address _buyer,
            address _seller,
            address _arbiter,
            uint256 amount,
            uint256 platformFee,
            uint256 createdAt,
            uint256 deliveryDeadline,
            MultiPartyEscrow.EscrowStatus status,
            bool sellerConfirmedDelivery,
            bool buyerReleasedPayment
        ) = escrow.escrows(0);

        assertEq(_buyer, buyer);
        assertEq(_seller, seller);
        assertEq(_arbiter, arbiter);
        assertEq(amount, 0);
        assertEq(platformFee, 0);
        assertEq(createdAt, block.timestamp);
        assertEq(deliveryDeadline, deadline);
        assertEq(uint256(status), uint256(MultiPartyEscrow.EscrowStatus.Created));
        assertEq(sellerConfirmedDelivery, false);
        assertEq(buyerReleasedPayment, false);

        vm.stopPrank();
    }

    function testCreateEscrowInvalidSeller() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidSeller.selector);
        escrow.createEscrow(address(0), arbiter, block.timestamp + DELIVERY_DEADLINE);
    }

    function testCreateEscrowInvalidArbiter() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidArbiter.selector);
        escrow.createEscrow(seller, address(0), block.timestamp + DELIVERY_DEADLINE);
    }

    function testCreateEscrowSellerIsBuyer() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__SellerCannotBeBuyer.selector);
        escrow.createEscrow(buyer, arbiter, block.timestamp + DELIVERY_DEADLINE);
    }

    function testCreateEscrowArbiterIsBuyer() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidArbiter.selector);
        escrow.createEscrow(seller, buyer, block.timestamp + DELIVERY_DEADLINE);
    }

    function testCreateEscrowArbiterIsSeller() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidArbiter.selector);
        escrow.createEscrow(seller, seller, block.timestamp + DELIVERY_DEADLINE);
    }

    function testCreateEscrowInvalidDeadline() public {
        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidDeadline.selector);
        escrow.createEscrow(seller, arbiter, block.timestamp - 1);
    }

    function testFundEscrow() public {
        vm.startPrank(buyer);

        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        uint256 expectedPlatformFee = (ESCROW_AMOUNT * PLATFORM_FEE) / 10000;
        uint256 expectedEscrowAmount = ESCROW_AMOUNT - expectedPlatformFee;

        vm.expectEmit(true, true, false, true);
        emit EscrowFunded(escrowId, buyer, expectedEscrowAmount, expectedPlatformFee);

        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        (
            ,
            ,
            ,
            uint256 amount,
            uint256 platformFee,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status,
            ,
        ) = escrow.escrows(escrowId);

        assertEq(amount, expectedEscrowAmount);
        assertEq(platformFee, expectedPlatformFee);
        assertEq(uint256(status), uint256(MultiPartyEscrow.EscrowStatus.Funded));
        assertEq(escrow.accumulatedFees(owner), expectedPlatformFee);
        assertEq(address(escrow).balance, ESCROW_AMOUNT);

        vm.stopPrank();
    }

    function testFundEscrowOnlyBuyer() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(seller);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__OnlyBuyerCanFund.selector);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);
    }

    function testFundEscrowInvalidStatus() public {
        vm.startPrank(buyer);

        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidStatus.selector);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.stopPrank();
    }

    function testFundEscrowZeroAmount() public {
        vm.startPrank(buyer);

        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__AmountMustBeGreaterThanZero.selector);
        escrow.fundEscrow{value: 0}(escrowId);

        vm.stopPrank();
    }

    function testConfirmDelivery() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.expectEmit(true, true, false, false);
        emit DeliveryConfirmed(escrowId, seller);

        vm.prank(seller);
        escrow.confirmDelivery(escrowId);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status,
            bool sellerConfirmedDelivery,
        ) = escrow.escrows(escrowId);

        assertEq(uint256(status), uint256(MultiPartyEscrow.EscrowStatus.Delivered));
        assertEq(sellerConfirmedDelivery, true);
    }

    function testConfirmDeliveryOnlySeller() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__OnlySellerCanConfirm.selector);
        escrow.confirmDelivery(escrowId);
    }

    function testConfirmDeliveryInvalidStatus() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(seller);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidStatus.selector);
        escrow.confirmDelivery(escrowId);
    }

    function testConfirmDeliveryDeadlinePassed() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.warp(block.timestamp + DELIVERY_DEADLINE + 1);

        vm.prank(seller);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__DeadlinePassed.selector);
        escrow.confirmDelivery(escrowId);
    }

    function testReleasePaymentAfterDelivery() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.prank(seller);
        escrow.confirmDelivery(escrowId);

        uint256 expectedPlatformFee = (ESCROW_AMOUNT * PLATFORM_FEE) / 10000;
        uint256 expectedSellerAmount = ESCROW_AMOUNT - expectedPlatformFee;

        uint256 sellerBalanceBefore = seller.balance;

        vm.expectEmit(true, true, true, true);
        emit PaymentReleased(escrowId, buyer, seller, expectedSellerAmount);

        vm.expectEmit(true, false, false, true);
        emit EscrowCompleted(escrowId, expectedSellerAmount, expectedPlatformFee);

        vm.prank(buyer);
        escrow.releasePayment(escrowId);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status,
            ,
            bool buyerReleasedPayment
        ) = escrow.escrows(escrowId);

        assertEq(uint256(status), uint256(MultiPartyEscrow.EscrowStatus.Completed));
        assertEq(buyerReleasedPayment, true);
        assertEq(seller.balance, sellerBalanceBefore + expectedSellerAmount);
    }

    function testReleasePaymentWithoutDeliveryConfirmation() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        uint256 expectedPlatformFee = (ESCROW_AMOUNT * PLATFORM_FEE) / 10000;
        uint256 expectedSellerAmount = ESCROW_AMOUNT - expectedPlatformFee;

        uint256 sellerBalanceBefore = seller.balance;

        vm.prank(buyer);
        escrow.releasePayment(escrowId);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status,
            ,
            bool buyerReleasedPayment
        ) = escrow.escrows(escrowId);

        assertEq(uint256(status), uint256(MultiPartyEscrow.EscrowStatus.Completed));
        assertEq(buyerReleasedPayment, true);
        assertEq(seller.balance, sellerBalanceBefore + expectedSellerAmount);
    }

    function testReleasePaymentOnlyBuyer() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.prank(seller);
        escrow.confirmDelivery(escrowId);

        vm.prank(seller);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__OnlyBuyerCanRelease.selector);
        escrow.releasePayment(escrowId);
    }

    function testReleasePaymentInvalidStatus() public {
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        vm.prank(buyer);
        vm.expectRevert(MultiPartyEscrow.MultiPartyEscrow__InvalidStatus.selector);
        escrow.releasePayment(escrowId);
    }

    function testMultipleEscrows() public {
        uint256 escrowId1 = createAndFundEscrow(buyer, seller, arbiter);
        uint256 escrowId2 = createAndFundEscrow(buyer, seller, arbiter);

        assertEq(escrowId1, 0);
        assertEq(escrowId2, 1);
        assertEq(escrow.escrowCounter(), 2);

        (
            address buyer1,
            ,
            ,
            ,
            ,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status1,
            ,
        ) = escrow.escrows(escrowId1);

        (
            address buyer2,
            ,
            ,
            ,
            ,
            ,
            ,
            MultiPartyEscrow.EscrowStatus status2,
            ,
        ) = escrow.escrows(escrowId2);

        assertEq(buyer1, buyer);
        assertEq(buyer2, buyer);
        assertEq(uint256(status1), uint256(MultiPartyEscrow.EscrowStatus.Funded));
        assertEq(uint256(status2), uint256(MultiPartyEscrow.EscrowStatus.Funded));
    }

    function testPlatformFeeCalculation() public {
        uint256[4] memory amounts;
        amounts[0] = 1 ether;
        amounts[1] = 0.5 ether;
        amounts[2] = 2 ether;
        amounts[3] = 0.1 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.startPrank(buyer);

            uint256 escrowId = escrow.createEscrow(
                seller,
                arbiter,
                block.timestamp + DELIVERY_DEADLINE
            );

            escrow.fundEscrow{value: amounts[i]}(escrowId);

            uint256 expectedFee = (amounts[i] * PLATFORM_FEE) / 10000;
            uint256 expectedAmount = amounts[i] - expectedFee;

            (
                ,
                ,
                ,
                uint256 amount,
                uint256 platformFee,
                ,
                ,
                ,
                ,
            ) = escrow.escrows(escrowId);

            assertEq(amount, expectedAmount);
            assertEq(platformFee, expectedFee);

            vm.stopPrank();
        }
    }

    function testWhenPaused() public {
        escrow.pause();

        vm.prank(buyer);
        vm.expectRevert();
        escrow.createEscrow(seller, arbiter, block.timestamp + DELIVERY_DEADLINE);
    }

    function testUnpause() public {
        escrow.pause();
        escrow.unpause();

        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(
            seller,
            arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        assertEq(escrowId, 0);
    }

    function createAndFundEscrow(
        address _buyer,
        address _seller,
        address _arbiter
    ) internal returns (uint256) {
        vm.startPrank(_buyer);

        uint256 escrowId = escrow.createEscrow(
            _seller,
            _arbiter,
            block.timestamp + DELIVERY_DEADLINE
        );

        escrow.fundEscrow{value: ESCROW_AMOUNT}(escrowId);

        vm.stopPrank();

        return escrowId;
    }
}
