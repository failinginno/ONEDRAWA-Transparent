# Independent draw verification

The following procedure does not require trusting the ONEDRAW website.

## 1. Identify the pool

Identify the pool asset first. Read USDG pools from `OneDrawPoolManager` and native ETH pools from `OneDrawNativePoolManager`. Record capacity, tickets sold, status, randomness request ID, winning ticket and winner.

## 2. Verify ticket ownership

Review `TicketsPurchased` events for the pool. Ticket indexes are assigned sequentially. Reconstruct the wallet owning every index from `0` through `capacity - 1`.

## 3. Verify the randomness request

Match PoolManager's `RandomnessRequested` event to the adapter and Router request. The Router stores the consumer, pinned drand round, delivery state and final random word.

## 4. Recompute the result

Calculate:

```text
expectedWinningTicket = randomWord mod capacity
expectedWinner = owner of expectedWinningTicket
```

Compare both values with PoolManager's `WinnerSelected` event and stored pool result.

## 5. Verify settlement

The protocol fee is transferred to the matching asset vault only after winner selection: `FeeVault` for USDG or `NativeFeeVault` for ETH. The prize remains a manager liability until the recorded winner claims it. Confirm the `PrizePaid` event and the corresponding USDG transfer or native ETH payment when a claim occurs.

## Asset-specific checks

- For USDG, confirm the token address and `Transfer` events between participant, PoolManager, winner and FeeVault.
- For ETH, confirm the purchase transaction value equals `ticketPrice * quantity` and inspect native value transfers to the winner or refund claimant.
- Confirm the pool manager and fee vault belong to the same asset system. USDG and ETH accounting must not be combined.

## Failure and retry behavior

- An invalid drand signature cannot pass Router verification.
- A fulfilled Router request cannot be fulfilled again.
- Callback retry uses the same stored random word and consumer; it does not redraw.
- PoolManager rejects an already fulfilled request or a pool that already has a winner.
- An expired pool below capacity has no winner and participants claim refunds.
- In V2, a fully sold pool that remains in `DRAWING` for one hour without successful delivery also becomes refundable. Each wallet can recover only its recorded contribution.
