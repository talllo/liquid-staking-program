# Marinade fuzz harness (crucible / FuzzCorp)

A coverage-guided fuzz harness for the `marinade_finance` program, driven against a fork of real
mainnet Marinade state. Runtime invariants (P-0001…P-0014, incl. the P-0007 target-panic detector)
are asserted after every action.

- `src/main.rs` — the harness (generated + hand-written `SCOUT:*` regions).
- `fixtures/mainnet/**` — real mainnet account snapshots, embedded at compile time.
- `programs/marinade_program.so` — the target program, loaded at runtime.
- `idls/marinade.json` — the program IDL (read at compile time by `declare_fuzz_program!`).
- `build-bundle.sh` — builds the harness and assembles a FuzzCorp bundle under `build/bundle/`.

CI (`.github/workflows/fuzzcorp.yml`) builds this on every push to `main` and uploads it to
FuzzCorp (org `marinade`, project `liquid-staking-program`). Three documented findings are
suppressed in this campaign build so P-0007 surfaces only *new* panics; see the audit writeups.
