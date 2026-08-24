#!/usr/bin/env bash
set -euo pipefail

IDF_VERSION="v5.5.5"
BUILD_PROFILE="${PROMIST_BUILD_PROFILE:-development}"
case "$BUILD_PROFILE" in
  development|production) ;;
  *) echo "PROMIST_BUILD_PROFILE must be development or production." >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_DIR="$REPO_ROOT/ProMistIDF"
BUILD_ROOT="${PROMIST_BUILD_ROOT:-$PROJECT_DIR/.builds}"
BUILD_DIR="$BUILD_ROOT/build-$BUILD_PROFILE"
SDKCONFIG_PATH="$BUILD_ROOT/sdkconfig.$BUILD_PROFILE"
IDF_CHECKOUT="${PROMIST_IDF_PATH:-$HOME/esp/esp-idf-$IDF_VERSION}"

if [[ ! -f "$IDF_CHECKOUT/export.sh" ]]; then
  echo "ESP-IDF $IDF_VERSION is required at $IDF_CHECKOUT." >&2
  echo "Install it, or set PROMIST_IDF_PATH to the pinned checkout." >&2
  exit 2
fi
mkdir -p "$BUILD_ROOT"

if [[ "$BUILD_PROFILE" == production ]]; then
  SIGNING_KEY="$REPO_ROOT/keys/promist-secure-boot-signing-key.pem"
  if [[ ! -f "$SIGNING_KEY" ]]; then
    echo "Production Secure Boot key is required at $SIGNING_KEY (never commit it)." >&2
    exit 2
  fi
  DEFAULTS="$PROJECT_DIR/sdkconfig.defaults;$PROJECT_DIR/sdkconfig.production.defaults"
else
  DEFAULTS="$PROJECT_DIR/sdkconfig.defaults;$PROJECT_DIR/sdkconfig.development.defaults"
fi

# Each profile is generated from defaults in a script-owned directory. This
# prevents stale development settings from weakening a production build.
rm -rf -- "$BUILD_DIR"
rm -f -- "$SDKCONFIG_PATH" "$SDKCONFIG_PATH.old"

# shellcheck disable=SC1090,SC1091
source "$IDF_CHECKOUT/export.sh" >/dev/null
cd -- "$REPO_ROOT"

idf.py -C "$PROJECT_DIR" -B "$BUILD_DIR" \
  -DSDKCONFIG="$SDKCONFIG_PATH" \
  -DSDKCONFIG_DEFAULTS="$DEFAULTS" reconfigure >/dev/null

MATTER_COMPONENT="ProMistIDF/managed_components/espressif__esp_matter"
MATTER_PATCH="patches/esp-matter-1.6-stable-ble-identity.patch"
if git apply --check --directory="$MATTER_COMPONENT" "$MATTER_PATCH" 2>/dev/null; then
  git apply --directory="$MATTER_COMPONENT" "$MATTER_PATCH"
elif ! git apply --reverse --check --directory="$MATTER_COMPONENT" "$MATTER_PATCH" 2>/dev/null; then
  echo "esp-matter component does not match the pinned 1.6.0 source." >&2
  echo "Refusing to build without the non-bonding ProMist BLE patch." >&2
  exit 2
fi

if [[ "$BUILD_PROFILE" == production ]]; then
  "$SCRIPT_DIR/validate-production-config.sh" \
    "$SDKCONFIG_PATH" "$PROJECT_DIR/partitions.production-8mb.csv"
fi

if [[ "${PROMIST_CONFIGURE_ONLY:-0}" == 1 ]]; then
  echo "Configured $BUILD_PROFILE firmware at $SDKCONFIG_PATH"
  exit 0
fi

exec idf.py -C "$PROJECT_DIR" -B "$BUILD_DIR" \
  -DSDKCONFIG="$SDKCONFIG_PATH" \
  -DSDKCONFIG_DEFAULTS="$DEFAULTS" build
