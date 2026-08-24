#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <generated-sdkconfig> <production-partition-table>" >&2
  exit 2
fi

SDKCONFIG_PATH="$1"
PARTITION_PATH="$2"
[[ -f "$SDKCONFIG_PATH" ]] || { echo "Missing generated sdkconfig: $SDKCONFIG_PATH" >&2; exit 2; }
[[ -f "$PARTITION_PATH" ]] || { echo "Missing partition table: $PARTITION_PATH" >&2; exit 2; }

require_line() {
  local expected="$1"
  if ! grep -Fqx -- "$expected" "$SDKCONFIG_PATH"; then
    echo "PRODUCTION CONFIGURATION ERROR: required setting missing: $expected" >&2
    exit 3
  fi
}

for setting in \
  CONFIG_IDF_TARGET=\"esp32\" \
  CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y \
  CONFIG_PARTITION_TABLE_CUSTOM=y \
  CONFIG_PARTITION_TABLE_CUSTOM_FILENAME=\"partitions.production-8mb.csv\" \
  CONFIG_PARTITION_TABLE_OFFSET=0x10000 \
  CONFIG_SECURE_SIGNED_APPS=y \
  CONFIG_SECURE_BOOT=y \
  CONFIG_SECURE_BOOT_V1_ENABLED=y \
  CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=y \
  CONFIG_SECURE_BOOT_SIGNING_KEY=\"../keys/promist-secure-boot-signing-key.pem\" \
  CONFIG_SECURE_FLASH_ENC_ENABLED=y \
  CONFIG_SECURE_FLASH_ENCRYPTION_MODE_RELEASE=y \
  CONFIG_NVS_ENCRYPTION=y \
  CONFIG_NVS_SEC_KEY_PROTECT_USING_FLASH_ENC=y \
  CONFIG_BT_NIMBLE_SM_SC=y \
  CONFIG_BT_NIMBLE_SM_SC_ONLY=1 \
  CONFIG_BT_NIMBLE_SM_LVL=1 \
  CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y \
  CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK=y \
  CONFIG_BOOTLOADER_APP_SECURE_VERSION=1
do
  require_line "$setting"
done

for forbidden in \
  CONFIG_SECURE_BOOT_INSECURE=y \
  CONFIG_SECURE_FLASH_ENCRYPTION_MODE_DEVELOPMENT=y \
  CONFIG_BOOTLOADER_EFUSE_SECURE_VERSION_EMULATE=y
do
  if grep -Fqx -- "$forbidden" "$SDKCONFIG_PATH"; then
    echo "PRODUCTION CONFIGURATION ERROR: insecure setting enabled: $forbidden" >&2
    exit 3
  fi
done

python3 - "$PARTITION_PATH" <<'PY'
import csv
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rows = []
with path.open(newline="", encoding="utf-8") as stream:
    for raw in stream:
        if raw.lstrip().startswith("#") or not raw.strip():
            continue
        rows.extend(csv.reader([raw]))

entries = {row[0].strip(): [value.strip() for value in row] for row in rows}
required = {"nvs_keys", "nvs", "otadata", "ota_0", "ota_1"}
missing = sorted(required - entries.keys())
if missing:
    raise SystemExit("PRODUCTION PARTITION ERROR: missing " + ", ".join(missing))
if any(row[1] == "app" and row[2] == "factory" for row in entries.values()):
    raise SystemExit("PRODUCTION PARTITION ERROR: anti-rollback layout must not contain a factory app")
if "encrypted" not in entries["nvs_keys"][5:]:
    raise SystemExit("PRODUCTION PARTITION ERROR: nvs_keys is not flash-encrypted")
if "encrypted" in entries["nvs"][5:]:
    raise SystemExit(
        "PRODUCTION PARTITION ERROR: nvs must use NVS-layer encryption, "
        "not the raw flash-encryption partition flag"
    )
if entries["otadata"][2] != "ota" or entries["ota_0"][2] != "ota_0" or entries["ota_1"][2] != "ota_1":
    raise SystemExit("PRODUCTION PARTITION ERROR: invalid A/B OTA subtypes")
print("Production security configuration and A/B partition layout validated")
PY
