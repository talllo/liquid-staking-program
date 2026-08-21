# Mainnet fork fixtures (Marinade)

A one-time snapshot of the **real, self-consistent** Marinade mainnet account graph, for a
fork-fuzzing harness that replaces the synthetic isolated-world `setup()`. Loading these into
LiteSVM gives one shared, real world where cross-instruction sequences (deposit → liquid_unstake →
order_unstake → claim) run against consistent state — which is what makes the conservation
invariants (V1 no-free-value, F-family LP round-trip) and virtual-vs-real invariants (V2/V3)
actually testable, and yields multi-validator / real-stake coverage for free.

**Why authorities need no patching:** `crucible-test-context` builds the SVM with
`.with_sigverify(false)`, so the harness can pass the real mainnet `admin_authority` /
`validator_manager_authority` / `pause_authority` pubkeys as signers directly. The cloned State
stays byte-for-byte real.

## Snapshot (program `MarBmsSgKXdrN1egZf5sqe1TMai9K1rChYNDJgjq7aD`, state `8szGkuLTAux9XMgZ2vtY39jVSowEcpBfFfD8hXSEqdGC`)

Each `*.json` is `solana account <addr> --output json` (owner, lamports, base64 data). `_addresses.json`
maps role → address.

| fixture | address | owner | note |
|---|---|---|---|
| state | 8szG…qdGC | marinade | State (2616 B) |
| msol_mint | mSoLzYCx… | token | mSOL mint |
| lp_mint | LPmSozJJ… | token | LP mint |
| msol_leg | 7GgPYjS5… | token | liq-pool mSOL leg |
| treasury_msol_account | B1aLzaNM… | token | reward-fee treasury |
| operational_sol_account | opLSF7Ld… | system | bot/ops SOL |
| validator_list | DwFYJNnh… | marinade | 183 KB — all validators + scores |
| stake_list | Anv3XE7e… | marinade | 560 KB — all managed stakes |

## Borsh offset map (State data, after the 8-byte anchor discriminator)

Validated against real data (msol_mint@8 → known `mSoLz…`, lp_mint@385 → known `LPmSoz…`).
`List` = `account:Pubkey(32) item_size:u32 count:u32 _reserved1:Pubkey(32) _reserved2:u32` = 76 B.

```
msol_mint            @8      operational_sol_account @72     treasury_msol_account @104
stake_list.account   @150    validator_list.account  @264
liq_pool.lp_mint     @385    liq_pool.msol_leg        @420
```

## Still to snapshot (loader phase — need Rust PDA derivation)

These are program-derived (can't base58-derive in the python dump); the Rust loader derives them
with `Pubkey::find_program_address(&[state, seed], program)` and the graph is completed by fetching:
- `reserve_pda`      seed `b"reserve"`      (system-owned; holds stakeable SOL)
- liq-pool `sol_leg` seed `b"liq_sol"`      (system-owned; the SOL leg — needed for liquid_unstake/add/remove)
- authorities (bump-only, no account to clone): `msol_mint_authority` `b"st_mint"`,
  `liq_pool msol_leg_authority` `b"liq_st_sol_authority"`, `lp_mint_authority` `b"liq_mint"`,
  `stake_deposit`/`stake_withdraw` authorities.
- Later (crank/merge coverage): the individual stake accounts referenced in `stake_list` and their
  validator vote accounts.

## Loader design (next build, Rust in the harness)

1. `include_bytes!`/`include_str!` these fixtures (or a build-time embed).
2. In `setup()`, for each fixture: `ctx.create_account().pubkey(addr).owner(owner).lamports(l).data(&bytes).create()`.
3. Derive + fund the SOL PDAs (reserve, sol_leg) from the fixtures' `state` addr.
4. Set sysvars (Clock/EpochSchedule/StakeHistory/Rent) to the snapshot epoch.
5. Point every `action_*` and the invariants at this single shared world (drop the per-family
   isolated builders). P-0001/P-0002 generalize immediately; V1/V2/V3 become wireable.
