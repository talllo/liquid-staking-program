#!/usr/bin/env bash
# Build the Marinade crucible fuzz harness and assemble a FuzzCorp bundle.
#
# Output: fuzz/marinade/build/bundle/ — a self-contained bundle directory ready for
# `fuzz-up upload bundle` (see .github/workflows/fuzzcorp.yml).
#
# The harness embeds the mainnet-fork fixtures at compile time (include_bytes! over
# fixtures/mainnet/**) and loads the target program `.so` at runtime relative to its working
# directory, so the bundle ships the built binary plus programs/marinade_program.so under run/.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

echo "==> building harness (release, --features invariant_test)"
cargo build --release --locked --features invariant_test

bundle="$here/build/bundle"
rm -rf "$bundle"
mkdir -p "$bundle/bin" "$bundle/run/programs"

cp "$here/target/release/invariant_test" "$bundle/bin/invariant_test"
cp "$here/programs/marinade_program.so"  "$bundle/run/programs/marinade_program.so"

# Revision commit: the git SHA the bundle was built from (5-40 hex chars per manifest v3).
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
find "$bundle" -type f -printf '    %p\n' 2>/dev/null || find "$bundle" -type f
