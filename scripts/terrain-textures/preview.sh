#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
preview_dir="$(mktemp -d /tmp/naviastra-terrain-preview.XXXXXX)"
trap 'rm -rf "$preview_dir"' EXIT
# Compile the exact platform-independent drawing code, without its iOS target gate.
sed '1d;$d' "$project_dir/NaviAstra/Maps/iOS/MapTerrainPattern.swift" > "$preview_dir/MapTerrainPattern.swift"
cp "$project_dir/scripts/terrain-textures/preview.swift" "$preview_dir/main.swift"
python3 "$project_dir/scripts/with-global-build-lock.py" -- \
    xcrun swiftc "$preview_dir/MapTerrainPattern.swift" "$preview_dir/main.swift" -o "$preview_dir/preview"
"$preview_dir/preview" "$project_dir/docs/images/terrain-low-poly-preview.png"
