#!/usr/bin/env bash
# Build the Marinade crucible fuzz harness and assemble a FuzzCorp bundle.
#
# Output: fuzz/marinade/build/bundle/ — ready for `fuzz-up upload bundle`.
#
# Inputs it expects to be present (CI generates them; see .github/workflows/fuzzcorp.yml):
#   - programs/marinade_program.so  — the target program, built from this repo's program source
#     with the pinned anchor 0.27 / solana 1.14.29 toolchain (`anchor build`). Loaded at runtime.
#   - idls/marinade.json            — the program IDL from the same build. Read at compile time by
#     declare_fuzz_program!.
# Fixtures ship compressed (one archive instead of ~100 files) and are unpacked here — they are
# embedded at compile time via include_bytes!.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [ ! -d fixtures/mainnet ]; then
  echo "==> unpacking fixtures"
  mkdir -p fixtures
  tar -xzf fixtures-mainnet.tar.gz -C fixtures
fi

for f in programs/marinade_program.so idls/marinade.json; do
  if [ ! -f "$f" ]; then
    echo "error: $f is missing — build the program first (anchor build; see the workflow)." >&2
    exit 1
  fi
done

echo "==> building harness (release, --features invariant_test)"
cargo build --release --locked --features invariant_test

bundle="$here/build/bundle"
rm -rf "$bundle"
mkdir -p "$bundle/bin" "$bundle/run/programs"

cp "$here/target/release/invariant_test" "$bundle/bin/invariant_test"
cp "$here/programs/marinade_program.so"  "$bundle/run/programs/marinade_program.so"

# ------------------------------------------------------------------ coverage ---
# Source-level coverage needs two things the execution .so cannot provide, and it
# fails SILENTLY when either is missing (lines_found: 0, nothing rendered):
#
#   1. An UNSTRIPPED binary. `cargo build-bpf` strips target/deploy/*.so, so the
#      DWARF lives only in the pre-strip artifact. Under the solana 1.14.29 line
#      that is target/bpfel-unknown-unknown/release/ -- not the sbf-solana-solana/
#      path used by 1.16+ -- so search rather than hardcoding either.
#   2. The sources, staged so that stripping SourcesOriginalPath off each absolute
#      SF: path in the LCOV lands inside SourcesPathInBundle. The program is built
#      in a container mounted at /work, so DW_AT_comp_dir is /work and the SF paths
#      are /work/programs/marinade-finance/src/... We mirror the repo layout under
#      srcs/ and strip the shallow "/work/" prefix, which depends only on comp_dir
#      and not on directory depth.
repo="$(git -C "$here" rev-parse --show-toplevel)"

# Pick the first candidate that actually CARRIES DWARF. "not stripped" is not the
# test: `anchor build` leaves the symbol table intact while emitting zero compile
# units unless CARGO_PROFILE_RELEASE_DEBUG=2 is set, and such a file sails through
# every size/`file` check only to yield an empty coverage profile on the server.
dwarf_cu_count() {
  local so="$1" dd=""
  command -v llvm-dwarfdump >/dev/null 2>&1 && dd=llvm-dwarfdump
  [ -z "$dd" ] && command -v dwarfdump >/dev/null 2>&1 && dd=dwarfdump
  [ -z "$dd" ] && { echo -1; return; }   # cannot tell; caller treats as unknown
  $dd --debug-info "$so" 2>/dev/null | grep -c DW_TAG_compile_unit || echo 0
}

# ELF e_machine of the program actually being fuzzed. The symbols MUST come from a
# build of the same architecture: 263 is Solana Bytecode Format (cargo-build-sbf),
# 247 is plain EM_BPF (the deprecated cargo-build-bpf that `anchor build` invokes).
# Both execute, but crucible resolves coverage only for the 263 artifact, and a
# tree that has been built both ways leaves BOTH lying around -- so pick by match,
# not by whichever directory is listed first.
e_machine() { od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' '; }
prog_mach="$(e_machine "$here/programs/marinade_program.so")"

symbols=""
for cand in \
  "$repo/target/sbpf-solana-solana/release/marinade_finance.so" \
  "$repo/target/sbf-solana-solana/release/marinade_finance.so" \
  "$repo/target/bpfel-unknown-unknown/release/marinade_finance.so"; do
  [ -f "$cand" ] || continue
  cand_mach="$(e_machine "$cand")"
  if [ -n "$prog_mach" ] && [ "$cand_mach" != "$prog_mach" ]; then
    echo "==> coverage: skipping $(basename "$(dirname "$(dirname "$cand")")") -- e_machine $cand_mach != program $prog_mach" >&2
    continue
  fi
  cus="$(dwarf_cu_count "$cand")"
  if [ "$cus" = "0" ]; then
    echo "==> coverage: skipping $cand -- no DWARF (0 compile units)." >&2
    continue
  fi
  symbols="$cand"
  [ "$cus" != "-1" ] && echo "==> coverage: $(basename "$cand") e_machine=$cand_mach, $cus compile units"
  break
done

if [ -n "$symbols" ]; then
  # srcs mirrors the CONTENTS of programs/, i.e. srcs/marinade-finance/src/... so
  # that stripping the "<comp_dir>/programs/" prefix off an SF: path lands exactly
  # on a staged file. The server REJECTS an empty SourcesOriginalPath outright
  # ("SourcesOriginalPath is required when SourcesPathInBundle is set"), so the
  # prefix always ends in programs/ even when the DWARF carries no comp_dir.
  # srcs holds the CONTENTS of the crate's src/, paired with a prefix that ends at
  # .../src/. The shallower pairing (prefix "programs/" + srcs/marinade-finance/src)
  # is structurally identical to what exponent uses and our own guard accepts it,
  # but the SERVER rejects it here with "does not match any source file" -- so trust
  # the server, not the model, and use the prefix that names the crate explicitly.
  mkdir -p "$bundle/symbols" "$bundle/srcs"
  cp "$symbols" "$bundle/symbols/marinade_symbols.so"
  cp -R "$repo/programs/marinade-finance/src/." "$bundle/srcs/"

  # Reading DW_AT_comp_dir alone is NOT enough, and assuming "absent comp_dir
  # means repo-relative" is exactly what broke this: the cover task rejected
  # SourcesOriginalPath "programs/" with "does not match any source file in the
  # coverage profile", so the project rendered lines_found: 0 while every CI step
  # stayed green. These SBF artifacts often carry NO comp_dir at all, and their
  # unit paths are a mix (programs/<crate>/src/..., bare src/lib.rs for deps).
  # Derive the prefix from the actual compile-unit paths, and FAIL rather than
  # guess -- a wrong prefix is invisible until someone opens an empty dashboard.
  # NOTE the suffix: srcs/ mirrors the CONTENTS of programs/ (srcs/marinade-finance/
  # src/...), so the prefix must end at programs/ for the strip to land on a staged
  # file. Deriving a longer prefix would resolve to srcs/lib.rs and find nothing.
  if sources_original="$(./derive-sources-prefix.sh "$symbols" \
                          'programs/marinade-finance/src/' 2>/dev/null)" \
     && [ -n "$sources_original" ]; then
    echo "==> coverage: derived SourcesOriginalPath = $sources_original"
  else
    echo "==> coverage: ERROR -- no compile unit under programs/ in the symbols" >&2
    echo "    in $symbols. The cover task would fail and coverage would render EMPTY." >&2
    exit 1
  fi
  coverage_params=$'\n              "SymbolsPathInBundle":   "symbols/marinade_symbols.so",\n              "SourcesPathInBundle":   "srcs",\n              "SourcesOriginalPath":   "'"$sources_original"$'",'
  echo "==> coverage: staged $(basename "$symbols") + programs/marinade-finance/src"
  echo "==> coverage: SourcesOriginalPath = ${sources_original:-<empty>}"
else
  coverage_params=""
  echo "==> coverage: WARNING -- no marinade_finance.so WITH DWARF was found; the" >&2
  echo "    bundle will run but render NO source-level coverage. Build the program" >&2
  echo "    with CARGO_PROFILE_RELEASE_DEBUG=2 and CARGO_PROFILE_RELEASE_STRIP=none;" >&2
  echo "    without them anchor emits a symbol table but zero compile units." >&2
fi

commit="$(git -C "$here" rev-parse HEAD)"

# Lineage name is "marinade", not "marinade_invariants". The rename is deliberate:
# corpora are keyed per lineage and FuzzCorp exposes no delete, so renaming is the
# only way to retire a corpus. The old lineage held 7810 inputs generated against an
# earlier program build; replaying them produced an lcov with none of this program's
# own source in it, so the cover task failed with "SourcesOriginalPath ... does not
# match any source file" even though the manifest was correct. A fresh lineage lets
# explore build a corpus against the binary actually being shipped. The name also
# matches the rest of the fleet (loopscale, marginfi, shielded-pool).
cat > "$bundle/manifest.fc.json" <<EOF
{
  "Version": 3,
  "Revision": { "Commit": "$commit" },
  "Lineages": [
    {
      "Name": "marinade",
      "Confs": [
        {
          "Name": "invariant_test",
          "Driver": {
            "Type": "crucible",
            "Params": {$coverage_params
              "BinaryPathInBundle": "bin/invariant_test",
              "HarnessRunDirInBundle": "run"
            }
          },
          "Architecture": { "Name": "amd64" },
          "Cores": 4,
          "MemoryKiB": 4194304,
          "YieldTimeMinutes": 120
        }
      ]
    }
  ]
}
EOF

echo "==> bundle assembled at $bundle"
find "$bundle" -type f
