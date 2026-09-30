# ONEDRAW Protocol

ONEDRAW is an onchain prize draw protocol deployed on Robinhood Chain. The production system supports USDG token pools and native ETH pools through separate managers and fee vaults. Every pool operates with fixed terms: a defined prize, ticket price, capacity, duration and protocol fee. Ticket ownership, draw requests, results, prize claims and refunds are recorded onchain.

This repository contains the Solidity contracts and verification material for the production protocol.

## V2 security upgrade (deployed September 30, 2026)

The production application now uses the V2 addresses in the deployment table below. V2 makes the randomness provider immutable, binds each adapter to one manager only once, adds a one-hour permissionless refund path if a full pool remains stuck waiting for randomness, and raises the pool-capacity ceiling so the 500 and 1,000 USDG tiers can use 1 USDG tickets.

The V2 test suite currently passes 58 tests, including timeout-boundary, paused-refund, liability-coverage, winner-selection and invariant tests. Deployment gates and migration steps are listed in [docs/V2-UPGRADE-PLAN.md](docs/V2-UPGRADE-PLAN.md). Multisig/timelock administration and an independent third-party audit are intentionally tracked separately and are not represented as completed.

## Mainnet deployment

**Network:** Robinhood Chain Mainnet

**Chain ID:** `4663`

**Explorer:** [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com)

| Contract | Address |
| --- | --- |
| USDG V2 PoolManager | [`0xF134fA9F4A1cDAc561F9cb8b0f500A7d6Fc11B14`](https://robinhoodchain.blockscout.com/address/0xF134fA9F4A1cDAc561F9cb8b0f500A7d6Fc11B14) |
| USDG V2 FeeVault | [`0x78c2FFB13eaE458204AD12Cd396321555d84Ae25`](https://robinhoodchain.blockscout.com/address/0x78c2FFB13eaE458204AD12Cd396321555d84Ae25) |
| USDG V2 Randomness Adapter | [`0xb2A3FB4dA03248060284E1C55dd127e31cD8dc52`](https://robinhoodchain.blockscout.com/address/0xb2A3FB4dA03248060284E1C55dd127e31cD8dc52) |
| ETH V2 PoolManager | [`0xd4F3A6fF72f4D4d57Ec44240D79Bb3b15F6ffDcd`](https://robinhoodchain.blockscout.com/address/0xd4F3A6fF72f4D4d57Ec44240D79Bb3b15F6ffDcd) |
| ETH V2 FeeVault | [`0x4Cd5D04d96bfD7e7cdCedB831dEb42d92bED2A16`](https://robinhoodchain.blockscout.com/address/0x4Cd5D04d96bfD7e7cdCedB831dEb42d92bED2A16) |
| ETH V2 Randomness Adapter | [`0xf66eB3Cae9d8be7489Be80CEB693A1086f29Ee68`](https://robinhoodchain.blockscout.com/address/0xf66eB3Cae9d8be7489Be80CEB693A1086f29Ee68) |
| Shared OpenVRF Router | [`0x4820F1DABC267fD4dD8Cd00E1dB30B2Cbef1de0f`](https://robinhoodchain.blockscout.com/address/0x4820F1DABC267fD4dD8Cd00E1dB30B2Cbef1de0f) |

Users should verify contract addresses against this table before interacting with the protocol.

## Protocol architecture

### PoolManager

`OneDrawPoolManager` manages pool creation, ticket allocation, draw state, winner selection, prize claims and refunds. Pool economics are fixed when a pool is created and cannot be changed after ticket sales begin.

### Native ETH PoolManager

`OneDrawNativePoolManager` implements the same lifecycle for native ETH. A purchase must include the exact `ticketPrice * quantity` value. The native manager is deployed separately from the USDG manager, so neither contract can access or account for the other asset's balances.

### Randomness Adapter

`OpenVRFRandomnessProvider` binds each PoolManager request to an authenticated OpenVRF callback. A failed callback may be retried with the same stored random word; retrying does not create a new draw.

### OpenVRF Router

The Router records a future drand round for each request and verifies the submitted signature onchain. The verified round output is combined with request-specific values before delivery to the adapter.

### FeeVault

`FeeVault` accounts for protocol fees realized after successful settlement. Withdrawals are limited to the amount recorded in `accruedFees`; prize and refund liabilities are not held as withdrawable protocol fees.

`NativeFeeVault` applies the same accounting boundary to native ETH fees. ETH is recorded as withdrawable only after a successfully completed draw forwards the configured protocol fee.

## Winner selection

Tickets are indexed sequentially from `0` to `capacity - 1`. Once a pool reaches capacity and receives verified randomness, PoolManager selects the winner using the following rule:

```solidity
uint32 winningTicket = uint32(randomValue % pool.capacity);
address winner = _ticketOwners[pool.id][winningTicket];
```

The selected wallet is read from the ticket ownership recorded by the contract. PoolManager does not accept a winner address as an input to settlement.

## Draw lifecycle

1. A USDG or ETH pool is created with fixed economic and timing parameters.
2. Each purchase assigns one or more sequential ticket indexes to the buyer.
3. The first purchase starts the pool timer.
4. A pool that reaches capacity closes ticket sales and requests randomness.
5. OpenVRF verifies the designated drand round and delivers the random word.
6. PoolManager stores the winning ticket and corresponding wallet.
7. The recorded winner claims the prize from PoolManager.

If a pool expires below capacity, no winner is selected. Participants may claim the value of their tickets through the refund path.

## Independent verification

Every completed draw can be checked without relying on the ONEDRAW interface:

1. Read the pool capacity, request ID, winning ticket and winner from PoolManager.
2. Reconstruct ticket ownership from `TicketsPurchased` events.
3. Match the request with the adapter and OpenVRF Router records.
4. Read the fulfilled random word from the Router.
5. Calculate `randomWord % capacity`.
6. Confirm that the resulting ticket owner matches `WinnerSelected`.

The full procedure is documented in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Administrative scope

The protocol owner may create USDG and ETH pools and templates, enable or disable templates, pause new entry, and withdraw only accounted protocol fees. These permissions do not include replacing the V2 randomness provider or Router, setting a winning ticket, supplying a winner address, changing sold ticket ownership, accessing participant liabilities through a fee vault, or replacing a completed result.

See [docs/TRUST-MODEL.md](docs/TRUST-MODEL.md) for the complete authority and availability model.

In V2, PoolManager's randomness provider and the adapter's Router cannot be replaced after deployment. The adapter is bound to its PoolManager once. Other owner permissions remain until a later multisig/timelock migration.

## Repository structure

```text
src/
  OneDrawPoolManager.sol
  OneDrawNativePoolManager.sol
  OpenVRFRandomnessProvider.sol
  OneDrawPoolManagerV2.sol
  OneDrawNativePoolManagerV2.sol
  OpenVRFRandomnessProviderV2.sol
  FeeVault.sol
  NativeFeeVault.sol
  interfaces/
openvrf/
  OpenVRF.sol
test/
  OneDrawPoolManager.t.sol
  OpenVRFRandomnessProvider.t.sol
  OneDrawInvariant.t.sol
docs/
  VERIFICATION.md
  TRUST-MODEL.md
  V2-UPGRADE-PLAN.md
```

## Security

Contract source and public verification material improve transparency but do not eliminate smart-contract, infrastructure, wallet or economic risk. Deployed bytecode and contract state on Robinhood Chain are authoritative.

Please follow the responsible disclosure process in [SECURITY.md](SECURITY.md) when reporting a suspected vulnerability.

## License

Licensed under the [MIT License](LICENSE).
