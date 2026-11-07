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
    event CheckedIn(uint256 indexed bookingId, address indexed guest);
    event PaymentReleased(address indexed to, uint256 amount);
    event BookingCancelled(uint256 indexed bookingId, uint256 refundToGuest, uint256 paidToHotel);
    event NoShowClaimed(uint256 indexed bookingId, uint256 paidToHotel);

    bool private locked; // used by nonReentrant below

    // only the hotel wallet can call functions that use this
    modifier onlyHotel() {
        require(msg.sender == hotel, "Only the hotel can do this");
        _;
    }

    // only the guest who made this booking can call functions that use this
    modifier onlyGuest(uint256 bookingId) {
        require(msg.sender == bookings[bookingId].guest, "Only the guest of this booking can do this");
        _;
    }

    // stops someone calling back into a function while it is still sending money
    // (re-entrancy attack)
    modifier nonReentrant() {
        require(!locked, "Busy");
        locked = true;
        _;
        locked = false;
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

    // guest confirms they have arrived at the hotel
    // the contract then releases the money to the hotel
    function confirmCheckIn(uint256 bookingId) external onlyGuest(bookingId) nonReentrant {
        Booking storage b = bookings[bookingId];
        require(b.status == Status.Booked, "Booking is not active");

        // update the booking first, then send the money
        // (checks-effects-interactions, so nobody can get paid twice)
        b.status = Status.CheckedIn;
        uint256 amount = b.amountPaid;
        b.amountPaid = 0;

        _pay(hotel, amount);
        emit CheckedIn(bookingId, msg.sender);
    }

    // guest cancels before check-in
    // 24h or more before = full refund, less than 24h = 50% back and 50% to the hotel
    function cancelBooking(uint256 bookingId) external onlyGuest(bookingId) nonReentrant {
        Booking storage b = bookings[bookingId];
        require(b.status == Status.Booked, "Booking is not active");
        require(block.timestamp < b.checkInTime, "Check-in time has passed");

        b.status = Status.Cancelled;
        uint256 amount = b.amountPaid;
        b.amountPaid = 0;

        // free up the nights so someone else can book them
        uint256 firstDay = b.checkInTime / 1 days;
        for (uint256 d = 0; d < b.nights; d++) {
            dayTaken[b.roomId][firstDay + d] = false;
        }

        // work out the refund
        uint256 refund;
        if (block.timestamp + CANCEL_WINDOW <= b.checkInTime) {
            refund = amount;        // cancelled early, full refund
        } else {
            refund = amount / 2;    // cancelled late, half back
        }
        uint256 toHotel = amount - refund;

        _pay(b.guest, refund);
        if (toHotel > 0) {
            _pay(hotel, toHotel);
        }
        emit BookingCancelled(bookingId, refund, toHotel);
    }

    // guest never turned up, so once the stay is over the hotel can take the payment
    function claimNoShow(uint256 bookingId) external onlyHotel nonReentrant {
        Booking storage b = bookings[bookingId];
        require(b.status == Status.Booked, "Booking is not active");
        require(block.timestamp >= b.checkInTime + b.nights * 1 days, "Stay has not ended yet");

        b.status = Status.NoShow;
        uint256 amount = b.amountPaid;
        b.amountPaid = 0;

        _pay(hotel, amount);
        emit NoShowClaimed(bookingId, amount);
    }

    // returns all the details of one booking in one go (handy for testing in Remix)
    function getBooking(uint256 bookingId) external view returns (Booking memory) {
        return bookings[bookingId];
    }

    // shows how much money the contract is holding right now
    function escrowBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // helper that sends money and makes sure it actually went through
    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Payment failed");
        emit PaymentReleased(to, amount);
    }

    // runs once when the contract is deployed
    // whoever deploys it becomes the hotel
    constructor() {
        hotel = msg.sender;
    }
}