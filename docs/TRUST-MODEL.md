# Trust and authority model

Transparency requires documenting the powers that remain, not only the restrictions.

## Protocol owner can

- create pools and immutable pool templates;
- enable or disable templates;
- pause new entry and pool creation;
- unpause the protocol;
- configure the randomness provider used by future requests;
- withdraw only realized fees recorded by FeeVault;
- administer Router consumer and relayer authorization.

## Protocol owner cannot

- submit a winning wallet to PoolManager;
- rewrite ownership of sold ticket indexes;
- change the immutable economics of an existing pool;
- fulfill the same randomness request twice;
- reroll or replace a completed result;
- claim a prize assigned to another wallet;
- withdraw participant refund liabilities through FeeVault.

## Relayer boundary

An authorized relayer provides liveness, not discretion over a valid result. It can submit a drand signature or delay submission. The Router verifies the pinned round before deriving the random word. Callback retry preserves the same stored word and recipient.

## Remaining risks

- Owner actions can affect availability and future configuration.
- Relayer, RPC or host downtime can delay settlement.
- A website can display stale data; contract state is authoritative.
- Smart contracts, dependencies and wallets can contain implementation vulnerabilities.
- Public source does not replace independent security review.
