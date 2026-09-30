# ONEDRAW V2 security upgrade

**Deployment status:** deployed to Robinhood Chain Mainnet on September 30, 2026. Current addresses are published in the repository README. Source verification and production smoke testing remain release checklist items until separately recorded as complete.

V2 is a new, non-upgradeable deployment. It does not mutate or migrate balances from the existing
mainnet contracts. Existing pools remain governed by their original contracts until they complete or
refund.

## Security changes

- `randomnessProvider` is immutable in both PoolManagers. There is no owner function that can replace it.
- The OpenVRF adapter is bound to its manager exactly once and cannot be rebound.
- The adapter's OpenVRF router remains immutable.
- A fully sold pool that receives no completed randomness callback for one hour becomes refundable.
  Every participant can pull their exact contribution; the owner cannot redirect it.
- Permissionless retries continue to deliver the same verified random word. They do not reroll.
- Maximum capacity is 10,000, allowing the reviewed 1,000 USDG prize tier to use 1 USDG tickets:
  `1 USDG * 1,100 = 1,000 USDG prize + 100 USDG fee`.

## Deliberately deferred

- Moving ownership to a multisig and timelock.
- Independent third-party audit.

These items must remain disclosed until completed. V2 must not be described as independently audited.

## Required deployment order

1. Simulate `DeployRobinhoodMainnetV2` and `DeployNativeEthMainnetV2` without `--broadcast`.
2. Record bytecode, constructor arguments and predicted addresses.
3. Broadcast with the reviewed deployment wallet.
4. Accept two-step ownership transfers with the approved owner.
5. Authorize both V2 adapters on the existing OpenVRF router.
6. Fund each adapter with a bounded request-fee budget.
7. Verify every V2 source file on Blockscout.
8. Run real-value smoke tests for purchase, verified draw, prize claim, partial-pool refund and
   full-pool randomness-timeout refund.
9. Only after all checks pass, update the frontend addresses and publish the V2 transparency claims.
10. Leave the V1 frontend available for outstanding V1 claims/refunds until liabilities reach zero.

## Mainnet release gate

Do not switch the public frontend merely because compilation and local tests pass. Deployment addresses,
ownership, adapter authorization, funding, source verification and end-to-end mainnet transactions must
all be independently checked first.
