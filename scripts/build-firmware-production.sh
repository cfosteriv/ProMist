#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PROMIST_BUILD_PROFILE=production
exec "$SCRIPT_DIR/build-idf-matter.sh" "$@"
