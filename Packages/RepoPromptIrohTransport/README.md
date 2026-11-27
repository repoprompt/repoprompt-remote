# RepoPrompt Iroh transport

The repository-root `RepoPromptRemoteNetworking` package owns the Mac
gateway's transport and the iOS client. It provides the wire contract, framed
QUIC streams, endpoint identity verification, route selection diagnostics and
read recovery. The applications own authorization, Keychain access and UI.

## Pinned stack

The direct dependencies are exact pins and the complete resolved graph is committed in `rust/Cargo.lock`:

| Component | Pin | Why this API is used |
|---|---:|---|
| Rust | 1.92.0 | Reproducible Apple static libraries; targets are declared in `rust/rust-toolchain.toml`. |
| Iroh | 1.0.3 | `Endpoint::builder`, caller-supplied 32-byte `SecretKey`, authenticated endpoint IDs, ALPN, bidirectional QUIC streams, relay/direct addressing, and connection path snapshots. |
| UniFFI | 0.31.2 | Proc-macro exports, async Swift bindings, C header/modulemap generation, and static-library linkage. |
| Tokio | 1.47.1 | One two-thread runtime owned by the Rust library. |
| zeroize | 1.9.0 | Clears Swift-supplied transient secret buffers after endpoint construction. |

Primary capability references (checked 2026-07-30):

- Iroh 1.0.3 crate and endpoint model: <https://docs.rs/iroh/1.0.3/iroh/>
- Iroh endpoint API: <https://docs.rs/iroh/1.0.3/iroh/endpoint/struct.Endpoint.html>
- Iroh connection/path API: <https://docs.rs/iroh/1.0.3/iroh/endpoint/struct.Connection.html>
- UniFFI Swift bindings: <https://mozilla.github.io/uniffi-rs/latest/swift/overview.html>
- UniFFI Xcode/static-library integration: <https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html>

Iroh authenticates the endpoint ID cryptographically, but application authorization remains the caller's responsibility. The bridge exposes that ID so the application can enforce the paired-device policy.

## Security and ownership boundary

- Swift supplies exactly 32 secret bytes to `startEndpoint`; Rust does not generate, serialize, log, or write endpoint keys.
- `repoprompt-remote/1` is the only ALPN used by the safe Swift convenience API.
- Frames use a four-byte big-endian length. Requests are capped at 1 MiB and responses at 8 MiB before body allocation.
- Each connection permits at most eight active bidirectional streams; each endpoint accepts at most sixteen live connections.
- A response has a separate first-byte deadline, a progress deadline and a bounded size-aware transfer budget. A timed-out stream resets independently.
- A response still draining to the peer counts as active. The application idle check can release a connection after there are no streams in flight.
- The client can retry an eligible read on a new stream. Commands and legacy single-use pairing messages are sent once.
- UniFFI cancellation aborts the corresponding spawned runtime task. Endpoint shutdown aborts and awaits the accept task before awaiting Iroh endpoint close; `Drop` is a final abort/close safety net.

The Mac and iOS app each store their endpoint secret in Keychain.

## Build and automated verification

Install the pinned toolchain/targets (rustup also reads `rust/rust-toolchain.toml` when run in that directory), then:

```bash
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path rust/Cargo.toml
Scripts/build-xcframework.sh --locked
Scripts/verify-xcframework.sh
REPOPROMPT_IROH_USE_LOCAL_ARTIFACT=1 swift test
```

The generated XCFramework is ignored by Git. Normal app and SwiftPM builds download the same checksum-pinned release ZIP used by RepoPrompt CE. Set `REPOPROMPT_IROH_USE_LOCAL_ARTIFACT=1` for `swift test` or `xcodebuild` to use a locally generated framework. The transport CI builds and verifies that framework, and the Simulator job tests the uploaded copy.

The artifact contains:

- macOS arm64 + x86_64
- iOS device arm64
- iOS Simulator arm64 + x86_64
- generated Swift bindings, C headers, modulemaps, and UniFFI checksum guards

`verify-xcframework.sh` fails for a missing architecture, platform declaration, generated API, exported start symbol, header/modulemap, or any filesystem API added to the Rust bridge.
