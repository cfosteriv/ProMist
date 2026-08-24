#!/bin/sh
set -eu

PROMIST_TEST_OUTPUT_DIR="${PROMIST_TEST_OUTPUT_DIR:-/tmp/promist-tests-sanitized}" \
PROMIST_SANITIZER_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" \
  ./scripts/test-host.sh
echo "Host tests passed — ASan/UBSan clean"
