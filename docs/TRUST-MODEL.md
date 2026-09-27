# Trust and authority model

Transparency requires documenting the powers that remain, not only the restrictions.

## Protocol owner can

- create USDG and native ETH pools and immutable pool templates;
- enable or disable templates;
- pause new entry and pool creation;
- unpause the protocol;
- configure the randomness provider used by future requests;
- withdraw only realized fees recorded by the corresponding USDG or native ETH FeeVault;
- administer Router consumer and relayer authorization.

## Protocol owner cannot

- submit a winning wallet to PoolManager;
- rewrite ownership of sold ticket indexes;
- change the immutable economics of an existing pool;
- fulfill the same randomness request twice;
- reroll or replace a completed result;
- claim a prize assigned to another wallet;
- withdraw participant prize or refund liabilities through either FeeVault.

## Asset isolation

USDG and native ETH use separate PoolManager, randomness adapter and FeeVault deployments. The two managers share the OpenVRF Router but do not share custody or accounting. An administrative action in one manager cannot transfer funds held by the other manager.

## Relayer boundary

An authorized relayer provides liveness, not discretion over a valid result. It can submit a drand signature or delay submission. The Router verifies the pinned round before deriving the random word. Callback retry preserves the same stored word and recipient.

## Remaining risks

- Owner actions can affect availability and future configuration.
- Relayer, RPC or host downtime can delay settlement.
- A website can display stale data; contract state is authoritative.
- Smart contracts, dependencies and wallets can contain implementation vulnerabilities.
- Public source does not replace independent security review.
