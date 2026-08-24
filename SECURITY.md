# Security policy

ProMist is a development retrofit, not a supported consumer product or a
certified Matter device. There is no release support window or security patch
SLA.

## Reporting an issue

Report vulnerabilities privately to the repository owner with the affected
revision, a minimal reproduction, expected impact, and any proposed mitigation.
Do not publish owner credentials, household-linked identifiers, or a working
exploit against an installed appliance. SharkNinja product or firmware issues
should be reported to SharkNinja; ProMist is an independent project.

## Proprietary BLE ownership

The proprietary BLE service protects app controls, device naming, diagnostics,
Matter setup-payload retrieval, and ownership changes from a nearby client that
does not have the owner credential. Local panel and RF controls do not require
that credential.

Enrollment is physically authorized:

1. With an unowned fan powered off, holding FAN for five seconds opens a
   60-second enrollment window.
2. Firmware generates a random 256-bit owner key and returns it once over an
   encrypted Bluetooth LE connection.
3. The iPhone stores the key in Keychain under the full 64-bit device ID with
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
4. Later connections exchange fresh 256-bit nonces and prove the key with
   HMAC-SHA-256 over the protocol version, device ID, and both nonces.

Challenges are single-use, comparisons do not return early, and a disconnect
clears authentication. Privileged GATT writes, subscriptions, responses, and
request sequencing stay attached to the originating connection handle. A
reconnected client must authenticate again.

The shared NimBLE host permits two links so Matter commissioning and the
proprietary service can coexist. Only one link may own an authenticated
proprietary control session. Disconnecting the other link does not clear that
session; disconnecting its owner does.

Advertisements, shortened names, CoreBluetooth peripheral identifiers, and
radio addresses are discovery hints. The app verifies the full firmware device
ID before using a saved owner key.

## Credential storage and local records

Owner keys never enter SwiftData or UserDefaults. SwiftData contains
user-visible fan records and Apple Home association metadata; a small
UserDefaults index lets App Intents resolve saved devices without storing
secrets.

Deleting a saved fan removes and verifies the Keychain item before deleting the
SwiftData record. If Keychain deletion cannot be confirmed, the record remains
so the operation can be retried. A device-only Keychain item does not migrate
through phone backups, so replacing or losing the owner phone requires physical
recovery.

Firmware stores the owner key and runtime settings in NVS. Matter keeps its
network, fabric, operational identity, and access-control data in its standard
storage. Diagnostic records contain fixed numeric events; they must never hold
owner keys, authentication packets, Wi-Fi credentials, Matter operational
credentials, or device-attestation private keys.

## Recovery and reset behavior

An authenticated owner can reset proprietary connection information through
the app. Whole-device recovery requires holding OSCILLATION for ten seconds
while the fan is powered off and waiting for the feedback sequence. It erases
the proprietary owner key, BLE bonds, Matter fabrics, Wi-Fi credentials,
friendly name, diagnostics, custom settings, and learned oscillation data, then
restarts.

Holding MIST for ten seconds restarts the controller without erasing persisted
ownership, Matter, Wi-Fi, names, diagnostics, or learned settings.

Physical recovery intentionally allows a person with access to the fan to take
new ownership. This is the recovery path for a lost phone or credential; it is
not intended to resist an attacker who can open or reflash the controller.

## Matter access

Matter and proprietary BLE use separate credentials and permission models.
Membership in a Matter fabric grants the access configured by that fabric; it
does not grant the ProMist BLE owner key. The BLE owner key grants access to the
first-party service; it does not add a controller to a Matter fabric.

The app retrieves the device-specific Matter onboarding payload only after
proprietary authentication, then hands commissioning to Apple's Matter setup
flow. Matter PASE, fabric installation, and later access control remain handled
by Matter and Apple Home.

## Assumptions and known limitations

- Initial key delivery uses no-input/no-output “Just Works” pairing. The short
  physical window limits opportunity, but it does not stop an active
  man-in-the-middle or relay during enrollment.
- The post-enrollment HMAC authenticates the owner session but does not encrypt
  every proprietary packet at the application layer. BLE link protection still
  applies where negotiated.
- Development firmware permits legacy or LE Secure Connections pairing. The
  production configuration requires LE Secure Connections, but “Just Works”
  still does not authenticate the peer.
- Authentication throttling is limited. A product would need attempt limits,
  backoff, and a per-device setup secret or another authenticated enrollment
  interaction.
- The installed 4 MB development board has Secure Boot, flash encryption, and
  NVS encryption disabled. A physical attacker may extract or replace firmware
  and stored credentials.
- Matter uses development VID/PID and example attestation material rather than
  assigned production identity and per-device DAC/PAI credentials.
- The installed board has no OTA update or recovery image. Updates use a wired
  development connection.

The repository's separate 8 MB production build profile configures signed A/B
partitions, Secure Boot V1, release-mode flash encryption, encrypted NVS,
rollback, and anti-rollback. It is a build template, not a deployed security
claim: repository tooling does not install OTA images, provision keys, burn
eFuses, confirm a new image on-device, or provide a manufacturing recovery
process.

Production keys must be generated and held outside the repository. The fixed
credential in `protocol/protocol-fixtures.json` is test data and must never be
installed on a device.
