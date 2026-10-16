#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ustawienia dotyczą wyłącznie tego procesu i pobieranych podmodułów.
# Domyślny transport Git może kończyć pobieranie Valhalli błędem HTTP 400.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=http.version
export GIT_CONFIG_VALUE_0=HTTP/1.1
export GIT_CONFIG_KEY_1=protocol.version
export GIT_CONFIG_VALUE_1=0

exec xcodebuild -resolvePackageDependencies -scmProvider system \
    -project "$project_dir/NaviAstra.xcodeproj" -scheme NaviAstra
