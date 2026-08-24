#!/usr/bin/env python3
"""Validate canonical BLE fixtures and their Swift/C++ regression consumers."""
import hashlib
import hmac
import json
import pathlib
import re
import struct

root = pathlib.Path(__file__).resolve().parents[1]
fixture = json.loads((root / "protocol/protocol-fixtures.json").read_text())
assert fixture["protocolVersion"] == 2
assert fixture["byteOrder"] == "little-endian"
vectors = {item["name"]: item for item in fixture["vectors"]}

app_identifier = fixture["iosApplicationIdentifier"]
assert app_identifier == "com.demo.ProMist", "canonical app identifier changed"
project = (root / "ProMist/ProMist.xcodeproj/project.pbxproj").read_text()
keychain = (root / "ProMist/ProMist/Services/KeychainStore.swift").read_text()
central = (root / "ProMist/ProMist/Services/ProMistBLECentral.swift").read_text()
bundle_identifiers = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", project)
expected_bundle_identifiers = [
    app_identifier,
    app_identifier,
    f"{app_identifier}Tests",
    f"{app_identifier}Tests",
    f"{app_identifier}UITests",
    f"{app_identifier}UITests",
]
assert bundle_identifiers == expected_bundle_identifiers, (
    "Xcode bundle identifiers differ from the canonical values: "
    f"expected {expected_bundle_identifiers}, found {bundle_identifiers}"
)
assert f'"{app_identifier}.owner"' in keychain
assert f'subsystem: "{app_identifier}"' in central

gatt = fixture["gattSchema"]
swift_protocol = (root / "ProMist/ProMist/Models/ProMistBLEProtocol.swift").read_text()
swift_capabilities = (root / "ProMist/ProMist/Models/ProMistCapabilities.swift").read_text()
firmware = (root / "ProMistIDF/main/BleManager.cpp").read_text()
assert f'CBUUID(string: "{gatt["serviceUUID"]}")' in swift_protocol

required_block = swift_capabilities.split(
    "static let requiredSessionRequirements = [", 1
)[1].split("static let requiredSessionCharacteristics", 1)[0]
for characteristic in gatt["characteristics"]:
    swift_name = characteristic["swiftName"]
    suffix = characteristic["suffix"]
    full_uuid = f"6F8A{suffix:04X}-7C5A-4D8F-9B21-8D12D9B00100"
    swift_declaration = (
        f'static let {swift_name} = CBUUID(string: "{full_uuid}")'
    )
    assert swift_declaration in swift_protocol, f"missing Swift GATT UUID for {swift_name}"

    cpp_name = characteristic["cppName"]
    cpp_declaration = (
        f"const ble_uuid128_t {cpp_name} = PROMIST_UUID(0x{suffix:02x});"
    )
    assert cpp_declaration in firmware, f"missing firmware GATT UUID for {cpp_name}"

    swift_property_match = re.search(
        rf"ProMistBLEProtocol\.{swift_name}:\s*(\[[^\]]+\]|\.\w+)",
        swift_capabilities,
    )
    assert swift_property_match, f"missing Swift GATT properties for {swift_name}"
    swift_properties = swift_property_match.group(1)
    for prop in characteristic["properties"]:
        if prop != "writeEncrypted":
            assert f".{prop}" in swift_properties, (
                f"Swift GATT properties for {swift_name} omit {prop}"
            )

    cpp_characteristic = re.search(
        rf"\{{ &{cpp_name}\.u,(.*?)(?=\n    \{{ &(?:[A-Z_]+)_ID\.u|\n    \{{ nullptr)",
        firmware,
        re.S,
    )
    assert cpp_characteristic, f"missing firmware GATT definition for {cpp_name}"
    cpp_properties = cpp_characteristic.group(1)
    cpp_flags = {
        "read": "BLE_GATT_CHR_F_READ",
        "write": "BLE_GATT_CHR_F_WRITE",
        "notify": "BLE_GATT_CHR_F_NOTIFY",
        "writeEncrypted": "BLE_GATT_CHR_F_WRITE_ENC",
    }
    for prop in characteristic["properties"]:
        assert cpp_flags[prop] in cpp_properties, (
            f"firmware GATT properties for {cpp_name} omit {prop}"
        )

    required_reference = f"ProMistBLEProtocol.{swift_name}"
    assert (required_reference in required_block) == characteristic["sessionRequired"], (
        f"session requirement mismatch for {swift_name}"
    )

information = vectors["current-device-information"]
s = information["semantic"]
encoded = (bytes((fixture["protocolVersion"], s["hardwareRevision"]))
           + struct.pack("<H", s["featureFlags"])
           + bytes.fromhex(s["deviceID"])[::-1]
           + bytes(s["firmwareVersion"]) + bytes((0,)))
assert encoded.hex() == information["hex"], "device-information semantic/hex mismatch"

request = vectors["set-mist-request"]
s = request["semantic"]
encoded = bytes((2, s["opcode"], 0, s["value"])) + struct.pack("<I", s["requestID"])
assert encoded.hex() == request["hex"], "set-mist-request semantic/hex mismatch"

response = vectors["unauthorized-response"]
s = response["semantic"]
encoded = bytes((2, s["result"], s["opcode"], 0)) + struct.pack("<I", s["requestID"])
assert encoded.hex() == response["hex"], "unauthorized-response semantic/hex mismatch"

auth = vectors["authentication-hmac"]
message = (bytes((fixture["protocolVersion"],)) + bytes.fromhex(auth["deviceID"])[::-1]
           + bytes.fromhex(auth["clientNonceHex"])
           + bytes.fromhex(auth["deviceNonceHex"]))
digest = hmac.new(bytes.fromhex(auth["ownerKeyHex"]), message, hashlib.sha256).hexdigest()
assert digest == auth["hmacHex"], "authentication fixture HMAC mismatch"

consumers = {
    root / "tests/ble_protocol_test.cpp":
        (information["hex"], request["hex"], response["hex"]),
    root / "ProMist/ProMistTests/ProMistBLEProtocolTests.swift":
        (request["hex"], response["hex"], auth["hmacHex"]),
    root / "ProMist/ProMistTests/ProMistCapabilitiesTests.swift":
        (information["hex"],),
}
for consumer, expected_vectors in consumers.items():
    text = consumer.read_text()
    for expected in expected_vectors:
        assert expected.lower() in text.lower(), f"{consumer}: missing canonical vector {expected}"
print("Protocol fixtures and Swift/C++ consumers are consistent")
