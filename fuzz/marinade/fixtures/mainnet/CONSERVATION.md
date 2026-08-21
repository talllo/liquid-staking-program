# Marinade conservation-invariant catalog (crank/stake/management)

Source audit of `targets/liquid-staking-program/programs/marinade-finance/src`. Reference for
wiring fork invariants. Each identity is classed by what it needs to check.

## (A) FIELD-ONLY — from State fields alone (mostly definitions → weak as bug-catchers)
- I-A-cooling: `total_cooling_down == delayed_unstake_cooling_down + emergency_cooling_down` (mod.rs:208).
- I-A-tluc: `TLUC == total_active_balance + total_cooling_down + available_reserve_balance` (mod.rs:213).
- I-A-tvsl: `total_virtual_staked_lamports == TLUC.saturating_sub(circulating_ticket_balance)` (mod.rs:229).
- I-throttle: `stake_moved <= max_stake_moved_per_epoch.apply(TLUC)` when `last_stake_move_epoch==epoch`.

## (B) AGGREGATE — sum per-record; the real bug-catchers (guard as noted)
- **I-B-score**: `total_validator_score == Σ ValidatorRecord.score`. (add/remove_validator, set_validator_score)
- **I-B-activebal-validator**: `total_active_balance == Σ ValidatorRecord.active_balance`.
  GUARD: only when `delinquent_upgrader.is_done()` — the upgrade window breaks it by design.
- I-B-activebal-stake: `total_active_balance == Σ StakeRecord.last_update_delegated_lamports`
  (records Active && !is_emergency_unstaking). GUARD: only for cranked records (virtual mirror).
- I-B-cooling-stake: `delayed + emergency cooling == Σ cooling StakeRecord.last_update_delegated_lamports`
  split by is_emergency_unstaking.
- I-B-stakecount / validatorcount: `list.count == #records`.
- I-B-ticket: `circulating_ticket_balance == Σ TicketAccountData.lamports_amount`;
  `circulating_ticket_count == #tickets`. (order_unstake/claim)
- I-B-upgrade (only while !is_done): upgrader accumulators reconcile; per-validator
  `delinquent_upgrader_active_balance <= active_balance`; at finalize `delinquent_balance_left == 0`.

## (C) REAL-BACKED — need real on-chain balances (now available on the fork)
- I-C1: `available_reserve_balance <= reserve_pda.lamports() - rent_exempt_for_token_acc` (virtual may lag).
- **I-C-reserve-eq** (assert only right after update_active): `available_reserve_balance + rent_exempt == reserve_pda.lamports()` (update.rs:440).
- I-C2: `msol_supply == msol_mint.supply` after Update* reconciliation (may lag between cranks).
- I-C-stake-recon: per active StakeRecord `last_update_delegated_lamports == stake_account.delegation.stake`
  (enforced at op time by check_stake_amount_and_validator / require_eq; FP before crank).
- I-C-total-recon: `Σ real Marinade stake delegated == total_active_balance + total_cooling_down`
  (exact only after all epoch cranks).

## Virtual mirrors (any C-check on these FPs until the crank reconciles)
`available_reserve_balance`, `msol_supply`, each `StakeRecord.last_update_delegated_lamports`,
`lp_supply`; `msol_price` is FE-only.

## Per-crank conservation (what each op must preserve — TLUC-neutral unless noted)
- stake_reserve: reserve −X → (total+validator).active_balance +X, new StakeRecord(X). TLUC neutral.
- deactivate_stake: active −X → delayed_cooling +X. TLUC neutral. (partial: split record, sum conserved)
- emergency_unstake / partial_unstake: active −X → emergency_cooling +X; on_stake_moved(X) throttle.
- update_active: reward = new−last; (total+validator).active_balance += reward; mint reward_fee mSOL to
  treasury at OLD price; reconcile reserve (assert reserve-eq); msol_price non-decreasing.
- update_deactivated: cooling −delegated → reserve +delegated; **rent leaks to operational** (not in TLUC);
  StakeRecord removed.
- merge_stakes: total/validator.active_balance += extra_delegated (double-rent); source record removed;
  **rent → operational**.
- create_canonical_stake: relocate delegation to canonical PDA; balances UNCHANGED; net record count 0;
  **stray lamports → operational**.
- finalize_delinquent_upgrade: per-validator active_balance := delinquent_upgrader_active_balance (no
  double count); requires delinquent_balance_left → 0; restores I-B-activebal-validator after Done.

## GLOBAL fuzzing gotchas
- Gate all AGGREGATE (B) invariants on `delinquent_upgrader.is_done()`.
- Gate REAL-BACKED (C) invariants on "this account was cranked this epoch" (virtual-mirror lag).
- Do NOT write "total protocol SOL never decreases" — rent legitimately leaves to operational in
  update_deactivated / merge_stakes / create_canonical_stake.
- `update` begin() zeroes `staking_sol_cap` on external-mint detection — cap invariants must tolerate it.
