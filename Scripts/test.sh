#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift test --disable-sandbox --cache-path .build/package-cache --config-path .build/config --security-path .build/security "$@"
