# Marinade fuzz harness

Fuzzes `marinade_finance` against a snapshot of real mainnet state, checking a set of
invariants after every instruction. Runs on [FuzzCorp](https://github.com/asymmetric-research/crucible).

## Layout

- `src/main.rs` — the harness. Asserts invariants P-0001..P-0014 after each action; P-0007 reports
  target-program panics (arithmetic overflow, `unwrap`, out-of-bounds) that the VM otherwise hides
  as failed transactions. Fuzzing concentrates on a 5-validator/stake subset (`SCOUT_FORK_FUZZ_N`).
- `fixtures-mainnet.tar.gz` — mainnet account snapshots, embedded at build time. `build-bundle.sh`
  unpacks it to `fixtures/mainnet/`.
- `build-bundle.sh` — builds the harness and writes a FuzzCorp bundle to `build/bundle/`.

The target program (`programs/marinade_program.so`) and IDL (`idls/marinade.json`) are **not
committed** — CI builds them from this repo's program source with the pinned anchor 0.27 / solana
1.14.29 toolchain. To build locally, run `anchor build` and copy `target/deploy/marinade_finance.so`
→ `programs/marinade_program.so` and `target/idl/marinade_finance.json` → `idls/marinade.json` first.

## CI

`.github/workflows/fuzzcorp.yml` runs on every PR and on push to `main`: it builds the program from
that ref, builds the harness against it, and uploads the bundle — so each change is fuzzed against
its own program. It needs three repo settings: secret `FUZZ_API_KEY`, and vars
`FUZZ_ORGANIZATION=marinade` / `FUZZ_PROJECT=liquid-staking-program`.

Three already-reported findings are muted in this build so the run only surfaces new panics. The
`repro_findings` feature turns them back on to reproduce all three.
