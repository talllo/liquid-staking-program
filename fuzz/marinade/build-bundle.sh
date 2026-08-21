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

commit="$(git -C "$here" rev-parse HEAD)"

cat > "$bundle/manifest.fc.json" <<EOF
{
  "Version": 3,
  "Revision": { "Commit": "$commit" },
  "Lineages": [
    {
      "Name": "marinade_invariants",
      "Confs": [
        {
          "Name": "invariant_test",
          "Driver": {
            "Type": "crucible",
            "Params": {
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
