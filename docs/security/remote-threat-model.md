# RepoPrompt Remote security notes

This document describes the first-release trust boundary for the two agreed
repositories:

- Desktop: `bobtheitguy31337/repoprompt-ce`
- Mobile: this repository

The Mac is the sole executor, authorization boundary, and source of truth. The
phone is a paired control surface. The notification relay is an untrusted
transport component and must never be able to execute a command or answer an
interaction.

## Assets and trust boundaries

| Asset | Owner | Protection |
| --- | --- | --- |
| Agent processes, workspaces, credentials, and transcripts | Mac | Never leave the desktop authority boundary in plaintext |
| Paired-device bearer credential | Mac and paired phone Keychain | One device only; replaced by re-pairing; omitted from snapshots and diagnostics |
| TLS private key and certificate | Mac Keychain | Generated locally; certificate fingerprint is pinned during pairing and reconnect |
| Iroh endpoint secrets | Separate Mac and phone Keychain items | Stable 32-byte device-only identities; passed to Rust only while starting an endpoint; never included in QR, logs, or diagnostics |
| Iroh endpoint IDs | Public authenticated identities | QR/bearer binding is checked before application routing and again on every RPC |
| Notification content | Mac and paired phone | AES-GCM envelope derived from the paired credential; relay sees only routing metadata and ciphertext |
| Workspace identity | Mac | Mobile uses immutable workspace IDs, not filesystem paths |

## Threats and mitigations

### QR interception or replay

The QR payload contains the Mac's Iroh endpoint address and a short-lived,
single-use pairing secret. The phone verifies the Mac's endpoint identity
before sending the secret, and the Mac verifies the phone's authenticated
endpoint identity before accepting it. The Mac persists a pending credential
and binds it to the phone's attempt ID and endpoint. The phone saves the
credential before sending authenticated confirmation. Only the confirmed
credential authorizes application access.

The same phone can resume prepare or confirm after a lost reply or restart.
Either app can recover the saved intermediate state from Keychain. The Mac
can issue a new code after an attempt expires or the user cancels it. Existing
pairings remain readable. Fresh pairings require updated Mac and iPhone apps.

The authenticated session earns Connected status when the phone returns the
first snapshot's server-generated sync ticket. Offline views retain the last
sync, and the phone reconnects with backoff and jitter. An unconfirmed command
result asks the user to check the Mac before resubmitting.

### Transport eavesdropping or impersonation

Iroh uses authenticated QUIC with a RepoPrompt-specific ALPN. Each request
must come from the paired endpoint and present the current device ID and
unexpired credential. The application router also enforces per-command
authority. Replacing an endpoint key requires pairing again.

Iroh relay operators can observe endpoint transport metadata and timing, but
QUIC application frames remain end-to-end encrypted. RepoPrompt adds no relay
account, helper process, push dependency, background mode, or cloud-owned state.

### Stolen, expired, or replaced phone credential

The desktop stores one device credential in Keychain. A new pairing replaces
the previous credential, and explicit revocation removes it. Authorization is
checked on every read and mutation request, and credentials are rejected after
expiry or if the bearer value does not match exactly.

### Notification relay compromise

The relay URL is explicitly configured by the user and must use HTTPS, except
for loopback HTTP development URLs. The relay receives a device token, routing
metadata, and an opaque encrypted envelope. The payload contains only a
generic category/title/body and optional session identity; prompts, paths,
commands, transcript text, and secrets are not sent in plaintext. The phone
authenticates and decrypts the envelope using its paired credential before
opening the authoritative session.

Provider credentials and APNs/FCM deployment remain environment configuration;
they are intentionally not committed to either repository.

### Malformed or oversized requests

The Iroh bridge rejects oversized length prefixes before allocation. Swift
validates complete encoded frames, bounds responses and concurrent streams,
and rejects unsupported wire versions before routing.

### Stale or duplicated state

Events carry a monotonic desktop sequence and event ID. The phone rejects
desktop-ID mismatches, duplicate IDs, and sequence gaps. The bounded replay
buffer requests a full snapshot when a cursor is older than the retained
window. A notification is only a hint; the phone reconnects and reads the Mac
before presenting authoritative state.

## Residual risks and release gates

- A compromised paired phone can exercise the authority granted to it until
  the desktop revokes or replaces the credential.
- A user-configured relay provider can still observe routing metadata and
  delivery timing; it cannot decrypt the envelope without the paired
  credential.
- Production distribution still requires an Apple team, provisioning profile,
  production APNs entitlement, and a deployed provider relay. Those values must
  be supplied in release infrastructure rather than committed here.
- Iroh direct/relay operation does not change the one-device policy or the Mac's
  command authority. Multi-device pairing and RepoPrompt-operated relay/account
  administration require a separate threat-model review.
- Physical-device Wi-Fi-to-cellular reconnect and path telemetry remain a
  release gate; simulator or desktop loopback evidence is not cellular proof.

## Operational checks

Use the Remote settings diagnostics screen to confirm gateway state, last
successful request, event cursor, paired-device state, notification
registration, Iroh endpoint and path, relay configuration, and the
last transport error. If a phone is lost, revoke it from the Mac before pairing
another device.
