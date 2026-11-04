// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract HotelBooking {

    enum Status { Booked, CheckedIn, Cancelled, NoShow }

    struct Room {
        uint256 pricePerNight; // in wei
        bool exists;
    }

    struct Booking {
        address guest;
        uint256 roomId;
        uint256 checkInTime;  // unix timestamp
        uint256 nights;
        uint256 amountPaid;   // money held in escrow
        bytes32 bookingRef;   // keccak256 booking reference
        Status status;
    }

    address public immutable hotel;   // receiver
    uint256 public constant CANCEL_WINDOW = 1 days;
    uint256 public constant MAX_NIGHTS = 30;

    uint256 public roomCount;
    uint256 public bookingCount;

    mapping(uint256 => Room) public rooms;
    mapping(uint256 => Booking) public bookings;
    mapping(uint256 => mapping(uint256 => bool)) public dayTaken;

    constructor() {
        hotel = msg.sender;   // whoever deploys = the hotel
    }
}