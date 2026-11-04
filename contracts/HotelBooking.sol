// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Hotel booking contract for my DDT CA
// The guest pays into this contract, the contract holds the money,
// and then pays the hotel once the rules are met (escrow)

contract HotelBooking {

    // the 4 states a booking can be in
    enum Status { Booked, CheckedIn, Cancelled, NoShow }

    // a room just needs a price and a flag to show it exists
    struct Room {
        uint256 pricePerNight; // price is in wei (1 ETH = 10^18 wei)
        bool exists;
    }

    // everything we need to know about one booking
    struct Booking {
        address guest;        // wallet of the person who booked
        uint256 roomId;
        uint256 checkInTime;  // unix timestamp
        uint256 nights;
        uint256 amountPaid;   // money sitting in the contract for this booking
        bytes32 bookingRef;   // keccak256 hash used as the booking reference
        Status status;
    }

    address public immutable hotel;                 // the hotel is the receiver
    uint256 public constant CANCEL_WINDOW = 1 days; // cancel 24h before for a full refund
    uint256 public constant MAX_NIGHTS = 30;        // limit so the loop below stays small

    uint256 public roomCount;
    uint256 public bookingCount;

    mapping(uint256 => Room) public rooms;           // room id -> room
    mapping(uint256 => Booking) public bookings;     // booking id -> booking
    mapping(uint256 => mapping(uint256 => bool)) public dayTaken; // room id -> day -> booked or not

    // events get saved in the transaction logs so we can see what happened
    event RoomAdded(uint256 indexed roomId, uint256 pricePerNight);
    event RoomBooked(uint256 indexed bookingId, address indexed guest, uint256 roomId, uint256 amount, bytes32 bookingRef);

    // only the hotel wallet can call functions that use this
    modifier onlyHotel() {
        require(msg.sender == hotel, "Only the hotel can do this");
        _;
    }

    // hotel adds a new room with its price per night
    function addRoom(uint256 pricePerNight) external onlyHotel returns (uint256) {
        require(pricePerNight > 0, "Price must be above zero");
        roomCount++;
        rooms[roomCount] = Room(pricePerNight, true);
        emit RoomAdded(roomCount, pricePerNight);
        return roomCount;
    }

    // guest books a room and pays at the same time
    // the money stays in the contract, it does not go to the hotel yet
    function bookRoom(uint256 roomId, uint256 checkInTime, uint256 nights)
        external
        payable
        returns (uint256)
    {
        Room memory r = rooms[roomId];

        // basic checks before we accept the booking
        require(r.exists, "Room does not exist");
        require(msg.sender != hotel, "Hotel cannot book its own room");
        require(nights > 0 && nights <= MAX_NIGHTS, "Nights must be 1 to 30");
        require(checkInTime > block.timestamp, "Check-in must be in the future");
        require(msg.value == r.pricePerNight * nights, "Send the exact price");

        // go through each night and mark it as taken
        // if any night is already taken the whole booking fails (no double booking)
        uint256 firstDay = checkInTime / 1 days;
        for (uint256 d = 0; d < nights; d++) {
            require(!dayTaken[roomId][firstDay + d], "Room already booked for those dates");
            dayTaken[roomId][firstDay + d] = true;
        }

        bookingCount++;

        // make a unique booking reference by hashing the booking details
        bytes32 ref = keccak256(abi.encodePacked(msg.sender, roomId, checkInTime, bookingCount));

        // save the booking
        bookings[bookingCount] = Booking({
            guest: msg.sender,
            roomId: roomId,
            checkInTime: checkInTime,
            nights: nights,
            amountPaid: msg.value,
            bookingRef: ref,
            status: Status.Booked
        });

        emit RoomBooked(bookingCount, msg.sender, roomId, msg.value, ref);
        return bookingCount;
    }

    // runs once when the contract is deployed
    // whoever deploys it becomes the hotel
    constructor() {
        hotel = msg.sender;
    }
}