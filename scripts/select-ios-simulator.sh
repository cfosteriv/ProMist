#!/bin/sh
set -eu

# The app targets iOS 17.6. Current CI uses Xcode 26.5, so this helper selects an
# installed iOS 26.5-or-newer simulator without coupling tests to a model name.
xcrun simctl list runtimes available >&2
xcrun simctl list devices available >&2

python3 - <<'PY'
import json
import re
import subprocess

runtimes = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "runtimes", "available", "--json"], text=True
))["runtimes"]
eligible = {}
for runtime in runtimes:
    match = re.search(r"iOS-(\d+)-(\d+)", runtime["identifier"])
    if match and tuple(map(int, match.groups())) >= (26, 5):
        eligible[runtime["identifier"]] = tuple(map(int, match.groups()))

devices = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
))["devices"]
candidates = []
for runtime, version in eligible.items():
    for device in devices.get(runtime, []):
        if device.get("isAvailable") and "iPhone" in device["name"]:
            candidates.append((version, device["name"], device["udid"]))
if not candidates:
    raise SystemExit("No iOS 26.5-or-newer iPhone simulator is available for the current test setup")
_, name, udid = sorted(candidates, reverse=True)[0]
print(f"platform=iOS Simulator,id={udid}")
print(f"Selected {name} ({udid})", file=__import__("sys").stderr)
PY
