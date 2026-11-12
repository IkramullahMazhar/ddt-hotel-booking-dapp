"""
deploy_and_test.py
Compiles HotelBooking.sol, deploys it to a local Ganache blockchain and runs
through every booking scenario (sender = guest, receiver = hotel).

Run Ganache first (see run_demo.sh), then:  python scripts/deploy_and_test.py
"""

import json
from pathlib import Path

import solcx
from web3 import Web3
from web3.exceptions import ContractLogicError
from web3.logs import DISCARD

GANACHE_URL = "http://127.0.0.1:8545"
SOLC_VERSION = "0.8.24"
ROOT = Path(__file__).resolve().parent.parent
CONTRACT_FILE = ROOT / "contracts" / "HotelBooking.sol"
BUILD_DIR = ROOT / "build"
DAY = 24 * 60 * 60


# ---------- helpers ----------

def eth(w3, wei):
    return f"{w3.from_wei(wei, 'ether'):.4f} ETH"


def send(w3, fn, sender, value=0):
    """Send a transaction and wait for it to be mined."""
    tx_hash = fn.transact({"from": sender, "value": value})
    return w3.eth.wait_for_transaction_receipt(tx_hash)


def expect_revert(w3, fn, sender, value=0, label=""):
    """Try a transaction that SHOULD fail and print the reason."""
    try:
        send(w3, fn, sender, value)
        print(f"  [FAIL] {label}: transaction went through but should have been rejected")
    except ContractLogicError as err:
        reason = err.message.split("revert ")[-1]
        print(f"  [PASS] {label}: rejected -> \"{reason}\"")


def time_travel(w3, seconds):
    """Ganache-only: move the blockchain clock forward."""
    w3.provider.make_request("evm_increaseTime", [seconds])
    w3.provider.make_request("evm_mine", [])


def now(w3):
    return w3.eth.get_block("latest")["timestamp"]


# ---------- compile ----------

def compile_contract():
    if SOLC_VERSION not in [str(v) for v in solcx.get_installed_solc_versions()]:
        print(f"Installing solc {SOLC_VERSION} (first run only)...")
        solcx.install_solc(SOLC_VERSION)

    source = CONTRACT_FILE.read_text()
    out = solcx.compile_standard(
        {
            "language": "Solidity",
            "sources": {"HotelBooking.sol": {"content": source}},
            "settings": {
                "evmVersion": "paris",  # safest choice for Ganache
                "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}},
            },
        },
        solc_version=SOLC_VERSION,
    )
    c = out["contracts"]["HotelBooking.sol"]["HotelBooking"]
    abi, bytecode = c["abi"], c["evm"]["bytecode"]["object"]

    BUILD_DIR.mkdir(exist_ok=True)
    (BUILD_DIR / "HotelBooking.json").write_text(json.dumps({"abi": abi, "bytecode": bytecode}, indent=2))
    print("Compiled OK -> build/HotelBooking.json")
    return abi, bytecode


# ---------- main demo ----------

def main():
    w3 = Web3(Web3.HTTPProvider(GANACHE_URL))
    if not w3.is_connected():
        raise SystemExit("Cannot reach Ganache on " + GANACHE_URL + " - start it first.")

    hotel, guest_a, guest_b, guest_c, guest_d = w3.eth.accounts[:5]
    print(f"Connected to Ganache (chain id {w3.eth.chain_id})")
    print(f"Hotel   (receiver): {hotel}")
    print(f"Guest A (sender)  : {guest_a}\n")

    abi, bytecode = compile_contract()

    # 1. Deploy - the hotel owns the contract
    Factory = w3.eth.contract(abi=abi, bytecode=bytecode)
    receipt = send(w3, Factory.constructor(), hotel)
    hb = w3.eth.contract(address=receipt.contractAddress, abi=abi)
    print(f"\n1. Deployed HotelBooking at {receipt.contractAddress} (gas used {receipt.gasUsed})")

    # 2. Hotel adds a room
    price = w3.to_wei(0.05, "ether")
    send(w3, hb.functions.addRoom(price), hotel)
    print(f"2. Hotel added room 1 at {eth(w3, price)} per night")
    expect_revert(w3, hb.functions.addRoom(price), guest_a, label="Guest tries to add a room")

    # 3. Guest A books 2 nights, 3 days from now
    check_in = now(w3) + 3 * DAY
    hotel_before = w3.eth.get_balance(hotel)
    r = send(w3, hb.functions.bookRoom(1, check_in, 2), guest_a, value=2 * price)
    ev = hb.events.RoomBooked().process_receipt(r, errors=DISCARD)[0]["args"]
    print(f"\n3. Guest A booked room 1 for 2 nights, paid {eth(w3, ev['amount'])}")
    print(f"   Booking ref (keccak256): 0x{ev['bookingRef'].hex()}")
    print(f"   Money held in escrow by the contract: {eth(w3, hb.functions.escrowBalance().call())}")

    # 4. Rules that protect both sides
    print("\n4. Validation checks")
    expect_revert(w3, hb.functions.bookRoom(1, check_in, 1), guest_b, value=price, label="Guest B double-books same dates")
    expect_revert(w3, hb.functions.bookRoom(1, check_in + 10 * DAY, 1), guest_b, value=1, label="Guest B sends wrong amount")
    expect_revert(w3, hb.functions.confirmCheckIn(1), guest_b, label="Guest B checks in to Guest A's booking")

    # 5. Guest A checks in -> hotel gets paid
    send(w3, hb.functions.confirmCheckIn(1), guest_a)
    gained = w3.eth.get_balance(hotel) - hotel_before
    print(f"\n5. Guest A confirmed check-in -> hotel received {eth(w3, gained)}")
    print(f"   Escrow now: {eth(w3, hb.functions.escrowBalance().call())}")

    # 6. Early cancellation -> full refund
    ci_b = now(w3) + 10 * DAY
    send(w3, hb.functions.bookRoom(1, ci_b, 1), guest_b, value=price)
    r = send(w3, hb.functions.cancelBooking(2), guest_b)
    ev = hb.events.BookingCancelled().process_receipt(r, errors=DISCARD)[0]["args"]
    print(f"\n6. Guest B cancelled 10 days early -> refund {eth(w3, ev['refundToGuest'])}, hotel {eth(w3, ev['paidToHotel'])}")

    # 7. Late cancellation (< 24h) -> 50 / 50
    ci_c = now(w3) + 5 * DAY
    send(w3, hb.functions.bookRoom(1, ci_c, 2), guest_c, value=2 * price)
    time_travel(w3, ci_c - now(w3) - 12 * 60 * 60)  # jump to 12 hours before check-in
    r = send(w3, hb.functions.cancelBooking(3), guest_c)
    ev = hb.events.BookingCancelled().process_receipt(r, errors=DISCARD)[0]["args"]
    print(f"7. Guest C cancelled 12h before -> refund {eth(w3, ev['refundToGuest'])}, hotel {eth(w3, ev['paidToHotel'])}")

    # 8. No-show -> hotel claims after the stay
    ci_d = now(w3) + 2 * DAY
    send(w3, hb.functions.bookRoom(1, ci_d, 1), guest_d, value=price)
    print("\n8. No-show test")
    expect_revert(w3, hb.functions.claimNoShow(4), hotel, label="Hotel claims before the stay ends")
    time_travel(w3, 4 * DAY)
    r = send(w3, hb.functions.claimNoShow(4), hotel)
    ev = hb.events.NoShowClaimed().process_receipt(r, errors=DISCARD)[0]["args"]
    print(f"   Guest D never arrived -> hotel claimed {eth(w3, ev['paidToHotel'])}")

    # 9. Final state
    status_names = ["Booked", "CheckedIn", "Cancelled", "NoShow"]
    print("\n9. Final booking table")
    for i in range(1, hb.functions.bookingCount().call() + 1):
        b = hb.functions.getBooking(i).call()
        print(f"   #{i}  guest {b[0][:10]}...  nights {b[3]}  status {status_names[b[6]]}")
    print(f"   Escrow balance: {eth(w3, hb.functions.escrowBalance().call())}")
    print("\nAll scenarios finished.")


if __name__ == "__main__":
    main()
