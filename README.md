# ONEDRAW Protocol Transparency

Public reference implementation and verification material for the ONEDRAW prize draw protocol deployed on Robinhood Chain Mainnet.

This repository is intentionally limited to the protocol surfaces required to understand and independently verify a draw. It does not contain private keys, RPC credentials, relayer configuration, operator tooling, deployment caches, or the private administration interface.

## Core guarantee

The operator does not submit a winning wallet. After a pool is completely sold, the deployed contracts derive one ticket index from a proof-verified random word:

```solidity
uint32 winningTicket = uint32(randomValue % pool.capacity);
address winner = _ticketOwners[pool.id][winningTicket];
```

The winner is therefore the wallet already recorded as the owner of the selected ticket.

## Mainnet contracts

| Contract | Address |
| --- | --- |
| PoolManager | [`0x8cb41dCCeA0ce11108f72b9ca6fd080DcE728096`](https://robinhoodchain.blockscout.com/address/0x8cb41dCCeA0ce11108f72b9ca6fd080DcE728096) |
| FeeVault | [`0x493c4e56eE3C8Be45b50455fBCFE8e831C05e5e6`](https://robinhoodchain.blockscout.com/address/0x493c4e56eE3C8Be45b50455fBCFE8e831C05e5e6) |
| Randomness Adapter | [`0x95CA6615b4c0514B56b07631A010d488B4EB2B99`](https://robinhoodchain.blockscout.com/address/0x95CA6615b4c0514B56b07631A010d488B4EB2B99) |
| OpenVRF Router | [`0x4820F1DABC267fD4d8Cd00E1dB30B2Cbef1de0f`](https://robinhoodchain.blockscout.com/address/0x4820F1DABC267fD4d8Cd00E1dB30B2Cbef1de0f) |

Network: Robinhood Chain Mainnet (`chainId 4663`).

## Draw lifecycle

1. Every purchase assigns sequential ticket indexes to the buyer wallet onchain.
2. When `ticketsSold == capacity`, sales close and PoolManager requests randomness.
3. OpenVRF pins a future drand round before its signature is available.
4. An authorized relayer submits the signature; the Router verifies the pinned round onchain.
5. The adapter forwards the verified word to PoolManager.
6. PoolManager applies the fixed modulo rule and stores the winning ticket and wallet.
7. Only the recorded winner can call `claimPrize`.

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for an independent verification checklist and [docs/TRUST-MODEL.md](docs/TRUST-MODEL.md) for the complete authority boundary.

## Repository map

- `src/OneDrawPoolManager.sol` — pools, tickets, deterministic selection, claims and refunds.
- `src/FeeVault.sol` — realized protocol-fee accounting and owner withdrawal limits.
- `src/OpenVRFRandomnessProvider.sol` — authenticated Router adapter and retry semantics.
- `openvrf/OpenVRF.sol` — deployed Router reference source and drand verification flow.
- `test/` — unit, fuzz and invariant tests used by the protocol project.

## Security scope

Public source improves verifiability; it is not by itself an audit or a guarantee that software is free of defects. Contract state on Robinhood Chain is authoritative. Users should verify addresses and bytecode before relying on any interface.

Responsible disclosure guidance is available in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
