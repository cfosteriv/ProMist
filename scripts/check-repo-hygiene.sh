#!/bin/sh
set -eu

python3 - <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse

tracked = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
).decode().split("\0")
tracked = [path for path in tracked if path and pathlib.Path(path).is_file()]
canonical_markdown = {
    "README.md",
    "SECURITY.md",
    "ProMist/README.md",
    "ProMistIDF/README.md",
}
tracked_markdown = {path for path in tracked if path.lower().endswith(".md")}
if tracked_markdown != canonical_markdown:
    missing = sorted(canonical_markdown - tracked_markdown)
    unexpected = sorted(tracked_markdown - canonical_markdown)
    details = []
    if missing:
        details.append("Missing canonical Markdown:\n" + "\n".join(missing))
    if unexpected:
        details.append("Unexpected Markdown:\n" + "\n".join(unexpected))
    print("\n".join(details), file=sys.stderr)
    raise SystemExit(1)
junk = re.compile(
    r"(^|/)(\.DS_Store|__MACOSX|__pycache__|xcuserdata|DerivedData)(/|$)|"
    r"^ProMistIDF/(managed_components|build|\.builds)(/|$)|"
    r"^ProMistIDF/sdkconfig(?:\.old| [0-9]+)?$|"
    r"^Archive.*\.zip$|"
    r"\.(pyc|xcuserstate|xcresult|elf|bin|map|o|a|d)$"
)
bad = [path for path in tracked if junk.search(path)]
if bad:
    print("Tracked generated/developer junk:\n" + "\n".join(bad), file=sys.stderr)
    raise SystemExit(1)

for name in tracked:
    if name.endswith(".json"):
        with open(name, encoding="utf-8") as stream:
            json.load(stream)

scan_extensions = {".c", ".cc", ".cpp", ".h", ".hpp", ".swift", ".sh", ".py", ".md", ".yml", ".yaml", ".json", ".txt"}
# This checker necessarily contains the patterns it detects. CI docs also show
# a generic local path as a deliberate negative example.
allow = {
    "scripts/check-repo-hygiene.sh",
    ".github/workflows/project-tests.yml",
}
patterns = [re.compile(rb"/Users/"), re.compile(rb"C:\\\\Users\\\\", re.I), re.compile(rb"DerivedData/")]
leaks = []
for name in tracked:
    path = pathlib.Path(name)
    if name in allow or path.suffix.lower() not in scan_extensions:
        continue
    data = path.read_bytes()
    if any(pattern.search(data) for pattern in patterns):
        leaks.append(name)
if leaks:
    print("Developer-local absolute path found in:\n" + "\n".join(leaks), file=sys.stderr)
    raise SystemExit(1)

broken_links = []
link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
for name in tracked:
    if not name.endswith(".md"):
        continue
    source = pathlib.Path(name)
    text = source.read_text(encoding="utf-8")
    for raw_target in link_pattern.findall(text):
        target = raw_target.strip().split()[0].strip("<>")
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = urllib.parse.unquote(target.split("#", 1)[0])
        if target and not (source.parent / target).resolve().exists():
            broken_links.append(f"{name}: {raw_target}")
if broken_links:
    print("Broken relative Markdown links:\n" + "\n".join(broken_links), file=sys.stderr)
    raise SystemExit(1)
print(f"Validated {sum(name.endswith('.json') for name in tracked)} JSON files; repository hygiene clean")
PY

python3 - <<'PY'
import pathlib
import sys

required_workflows = {
    ".github/workflows/project-tests.yml": [
        "shellcheck scripts/*.sh",
        "./scripts/check-repo-hygiene.sh",
        "./scripts/test-host.sh",
        "./scripts/test-host-sanitized.sh",
        "xcodebuild test",
        "v5.5.5",
        "./scripts/build-firmware-dev.sh",
    ],
}
failures = []
for name, commands in required_workflows.items():
    path = pathlib.Path(name)
    if not path.is_file():
        failures.append(f"{name}: workflow is missing")
        continue
    text = path.read_text(encoding="utf-8")
    for command in commands:
        if command not in text:
            failures.append(f"{name}: missing documented command {command!r}")
if failures:
    print("CI workflow contract failed:\n" + "\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
print("Validated the documented Project Tests workflow")
PY

python3 - <<'PY'
import pathlib
import re
import sys

roots = [
    pathlib.Path("ProMistIDF/main"),
    pathlib.Path("ProMistIDF/CMakeLists.txt"),
    pathlib.Path("ProMistIDF/sdkconfig.defaults"),
    pathlib.Path("ProMistIDF/sdkconfig.development.defaults"),
    pathlib.Path("ProMistIDF/sdkconfig.production.defaults"),
    pathlib.Path("ProMistIDF/dependencies.lock"),
    pathlib.Path("scripts"),
    pathlib.Path(".github"),
]
patterns = {
    "Arduino header": re.compile(r"#\s*include\s*[<\"]Arduino\.h[>\"]"),
    "Arduino storage": re.compile(r"#\s*include\s*[<\"]Preferences\.h[>\"]"),
    "Arduino Wi-Fi": re.compile(r"#\s*include\s*[<\"]WiFi\.h[>\"]"),
    "Arduino Matter": re.compile(r"#\s*include\s*[<\"]Matter\.h[>\"]"),
    "Arduino component": re.compile(r"(?:REQUIRES|PRIV_REQUIRES)\s+arduino\b"),
    "Arduino path": re.compile(r"PROMIST_ARDUINO"),
    "Arduino configuration": re.compile(r"CONFIG_ARDUINO|arduino-esp32|components/arduino"),
    "Arduino storage API": re.compile(r"\bPreferences\b"),
    "Arduino string type": re.compile(r"\bString\b"),
    "Arduino logging": re.compile(r"\bSerial\."),
    "Arduino lifecycle": re.compile(r"\bsetup\s*\(|\bvoid\s+loop\s*\("),
    "Arduino convenience API": re.compile(
        r"\b(?:digitalWrite|digitalRead|pinMode|attachInterrupt|detachInterrupt|"
        r"digitalPinToInterrupt|ledcWrite|ledcSetup|ledcAttachPin|analogWrite|"
        r"millis|micros|delay|delayMicroseconds|yield)\s*\("
    ),
    "retired Arduino Matter owner": re.compile(r"ArduinoMatterFan"),
}
violations = []
files = []
for root in roots:
    if root.is_file():
        files.append(root)
    elif root.exists():
        files.extend(path for path in root.rglob("*") if path.is_file())
for path in files:
    if path.as_posix() == "scripts/check-repo-hygiene.sh":
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for label, pattern in patterns.items():
        if pattern.search(text):
            violations.append(f"{path}: {label}")
if violations:
    print("Prohibited firmware dependency found:\n" + "\n".join(violations), file=sys.stderr)
    raise SystemExit(1)
print("Native ESP-IDF dependency purity check passed")
PY

./scripts/check-protocol-fixtures.py
