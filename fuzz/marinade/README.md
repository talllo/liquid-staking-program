# Marinade fuzz harness

Fuzzes `marinade_finance` against a snapshot of real mainnet state, checking a set of
invariants after every instruction. Runs on [FuzzCorp](https://github.com/asymmetric-research/crucible).

## Layout

- `src/main.rs` — the harness. Asserts invariants P-0001..P-0014 after each action; P-0007 reports
  target-program panics (arithmetic overflow, `unwrap`, out-of-bounds) that the VM otherwise hides
  as failed transactions.
- `fixtures/mainnet/` — mainnet account snapshots, embedded at build time.
- `programs/marinade_program.so` — the target program, loaded at runtime.
- `idls/marinade.json` — the program IDL, read at build time.
- `build-bundle.sh` — builds the harness and writes a FuzzCorp bundle to `build/bundle/`.

## CI

`.github/workflows/fuzzcorp.yml` builds and uploads the bundle on every push to `main`. It needs
three repo settings: secret `FUZZ_API_KEY`, and vars `FUZZ_ORGANIZATION=marinade` /
`FUZZ_PROJECT=liquid-staking-program`.

Three already-reported findings are muted in this build so the run only surfaces new panics. The
`repro_findings` feature turns them back on to reproduce all three.
