# RepoPrompt Remote

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue)

RepoPrompt Remote is the iPhone and iPad companion for **[this RepoPrompt CE desktop fork](https://github.com/bobtheitguy31337/repoprompt-ce)**. It lets you follow and control Agent Mode sessions from another room or on the other side of the earth while your Mac continues to run the agents, own the workspaces, and enforce every permission.

> [!IMPORTANT]
> RepoPrompt Remote is developed and tested with [`bobtheitguy31337/repoprompt-ce`](https://github.com/bobtheitguy31337/repoprompt-ce). That fork contains the matching macOS Remote Gateway. Other RepoPrompt CE builds or forks are not guaranteed to expose a compatible gateway.

## What you can do

- Browse the workspaces and chats available on your Mac.
- Follow live transcripts, run state, tool activity, and parent/child agent sessions.
- Send follow-ups and respond to questions or approval requests.
- Start sessions from the desktop's agents and workflows, including model and tool choices.
- Cancel or resume work when the authority granted by the Mac allows it.
- Attach files and photos from iOS to new chats and follow-ups on a matching Mac build.
- Reconnect and resynchronize after Wi-Fi or desktop interruptions.
- Optionally receive encrypted attention notifications through a self-hosted relay.

RepoPrompt Remote is a control surface—not a second agent runtime and not a network-exposed MCP server. It never opens repositories or runs providers on iOS. The paired Mac remains the source of truth and checks authorization again for every command.

## How the two repositories fit together

| Component | Repository | Responsibility |
| --- | --- | --- |
| RepoPrompt CE for macOS | [`bobtheitguy31337/repoprompt-ce`](https://github.com/bobtheitguy31337/repoprompt-ce) | Runs agents, owns workspaces and credentials, and hosts the opt-in Iroh Remote Gateway. |
| RepoPrompt Remote for iOS | This repository | Displays desktop state and sends authorized controls to the paired Mac. |
| Shared Swift protocol | [`Packages/RepoPromptRemoteProtocol`](Packages/RepoPromptRemoteProtocol) | Defines the Foundation-only snapshots, events, commands, and compatibility rules used by both apps. |

This repository owns the shared `RepoPromptRemoteNetworking` Swift package.
The iOS target uses it from this checkout, and RepoPrompt CE pins its revision.
`desktop-compatibility.json` records a previous desktop baseline for mixed-version
testing. Use a tested desktop checkout for local device integration.

```text
<parent>/
├── repoprompt-ce/
└── repoprompt-remote/
```

## Requirements

- A Mac capable of building and running the [compatible RepoPrompt CE fork](https://github.com/bobtheitguy31337/repoprompt-ce#source-build-requirements).
- Xcode 26.3 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- iOS or iPadOS 17 or later, or an iOS Simulator.
- A network connection on both devices. A shared local network lets Iroh connect directly.
- For a physical device, an Apple Developer team and a development signing profile.

This repository currently provides a source build rather than an App Store download.

## Quick start

### 1. Check out the matching desktop source

From the RepoPrompt Remote repository root, clone the compatible desktop revision beside it:

```sh
desktop_repo="$(python3 -c 'import json; print(json.load(open("desktop-compatibility.json"))["desktop_repository"])')"
desktop_revision="$(python3 -c 'import json; print(json.load(open("desktop-compatibility.json"))["desktop_revision"])')"
git clone "https://github.com/${desktop_repo}.git" ../repoprompt-ce
git -C ../repoprompt-ce checkout "$desktop_revision"
```

### 2. Build and launch the desktop app

Follow the desktop fork's [build and launch instructions](https://github.com/bobtheitguy31337/repoprompt-ce#build-and-launch-locally) at the pinned revision.

### 3. Build the iOS app

```sh
brew install xcodegen
xcodegen generate
open RepoPromptRemote.xcodeproj
```

In Xcode, select the **RepoPromptRemote** scheme and run it on an iOS Simulator or a connected device. For a physical device, choose your own development team in Signing & Capabilities. If necessary, use a bundle identifier registered to that team in your local build settings; do not commit personal signing or device values.

The command-line helpers use the app target’s signing settings. Set `DEVELOPMENT_TEAM` for a per-build override. List connected devices with `xcrun devicectl list devices`, then set `DEVICECTL_DEVICE_ID` when calling `./install-phone.sh`. The build helper accepts an optional `XCODE_DEVICE_ID` for device-specific builds.

SwiftPM downloads the same checksum-pinned Iroh XCFramework used by the desktop fork. Local Rust builds can opt into their generated framework by setting `REPOPROMPT_IROH_USE_LOCAL_ARTIFACT=1` when invoking SwiftPM or Xcode. See the [transport build instructions](Packages/RepoPromptIrohTransport/README.md).

A signing-free Simulator build is also available from the command line:

```sh
xcodebuild -project RepoPromptRemote.xcodeproj \
  -scheme RepoPromptRemote \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### 4. Pair the apps

1. In RepoPrompt CE on the Mac, open **Settings → Remote**.
2. Enable pairing and generate a pairing code.
3. On the iPhone or iPad, tap **Pair with Mac** and scan the QR code.
4. Confirm the paired Mac appears in RepoPrompt Remote.

For Simulator development, use **Copy pairing link** on the Mac and paste the `rpremote://` value into the Debug pairing field in the iOS app.

Only one phone is paired at a time. Pairing a replacement device invalidates the previous credential; you can also revoke a lost device from the Mac.

### Pairing diagnostics

The iOS app sends pairing failures to the [`repoprompt-remote` Sentry project](https://repoprompt.sentry.io/issues/?project=4512485498683392) when built with `REPOPROMPT_SENTRY_DSN`. Pass the client DSN as an Xcode build setting, or export it when using `./build-phone.sh`. The release workflow reads the same name from a GitHub Actions repository variable. Debug builds also accept a launch environment override. Set `REPOPROMPT_TELEMETRY_DISABLED=1` in the launch environment to turn off collection.

The macOS gateway sends its pairing diagnostics through the existing RepoPrompt CE Sentry configuration and telemetry preference. In Sentry, search Issues and Explore Logs across both projects for `pairing_attempt:<uuid>` to follow an attempt through preparation and confirmation. Failures before a pairing request reaches the Mac only have an iOS event. The diagnostic payload uses fixed stage and reason codes, the Iroh path category when available, and a UUID for each pairing attempt. It excludes pairing links, credentials, device names, endpoint addresses, and workspace content.

## Security model

Remote access is opt-in. Iroh connects the paired devices directly or uses an Iroh relay when a direct path is unavailable.

- Pairing uses a short-lived, one-time secret.
- Iroh authenticates both endpoint identities before sending credentials or routing a request.
- Long-lived device credentials are stored in Keychain on both devices.
- The Mac applies `observe`, `respond`, `control`, or `danger` authority to each request.
- Secret answers are sent once and are excluded from remote snapshots and history.
- Reconnects use replayable events or a fresh authoritative snapshot when needed.

Use RepoPrompt Remote only on a network you trust. If a phone is lost or compromised, revoke it from RepoPrompt CE immediately. See the [remote threat model](docs/security/remote-threat-model.md) for trust boundaries, mitigations, and residual risks.

## Optional notifications

The app works without push notifications. If you want attention alerts while it is in the background, this repository includes a provider-neutral [Node 20 relay](relay/) for APNs or FCM.

The relay receives routing metadata and an encrypted envelope—not plaintext prompts, paths, transcript content, commands, or secrets. It is still your responsibility to deploy it behind HTTPS and private access control and to supply provider credentials outside the repository. See the [relay documentation](relay/README.md) for configuration and deployment notes.

## Development

Regenerate `RepoPromptRemote.xcodeproj` after changing [`project.yml`](project.yml):

```sh
xcodegen generate
```

Run the shared protocol and relay test suites with:

```sh
swift test --package-path Packages/RepoPromptRemoteProtocol
npm --prefix relay test
```

When updating the desktop fork from `RepoPrompt/repoprompt-ce`, merge upstream into the Remote integration in an isolated checkout, resolve the Remote adapters against the current Agent Mode APIs, and run the desktop Remote tests and product build. Then run the canonical contract suite and the iOS test target:

```sh
# Run the canonical wire compatibility suite from this checkout.
swift test --package-path Packages/RepoPromptRemoteProtocol
xcodebuild -project RepoPromptRemote.xcodeproj -scheme RepoPromptRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

Pass a different desktop checkout path when using a worktree. Both applications build against the same contract source. Desktop compilation and paired-device acceptance verify the integration. Update `desktop-compatibility.json` to the tested desktop commit when delivering a coordinated update.

The CI workflow also generates the Xcode project and runs the app's unit tests on an available iOS Simulator.

See the desktop fork's [remote-control architecture](https://github.com/bobtheitguy31337/repoprompt-ce/blob/12eefd3beccf785c4b68986d685c2007cd4d47f2/docs/architecture/remote-control.md) and this repository's [security notes](docs/security/remote-threat-model.md).

## Repository layout

```text
Packages/RepoPromptRemoteProtocol/  Shared Foundation-only Swift contract
Sources/RepoPromptRemote/           SwiftUI iOS/iPadOS application
Tests/RepoPromptRemoteTests/        Mobile presentation and client tests
relay/                               Optional encrypted notification relay
docs/security/                       Threat model and operational guidance
.github/workflows/                   CI and manual archive workflows
```

## Contributing

Changes that affect the wire contract must remain compatible with both this app and the [matching desktop fork](https://github.com/bobtheitguy31337/repoprompt-ce). Keep both repositories checked out as siblings, regenerate the Xcode project when needed, and run the protocol and relay tests before opening a pull request.

## License

RepoPrompt Remote is licensed under the [Apache License, Version 2.0](LICENSE).
Third-party components retain their respective licenses. See the [Iroh transport notices](Packages/RepoPromptIrohTransport/THIRD_PARTY-NOTICES.md).

## Workspace Voice

Select a workspace in Remote and tap the waveform to start a call. Use the workspace picker switches to keep individual workspaces open on the Mac. The Start Voice widget and app shortcut use the workspace selected in Remote.

Choose a voice in **Settings → Workspace Voice → Voice**. Workspace Voice requires Control permission. Mac-wide Codex tool changes require Danger permission.

[Mac setup mockup](docs/mockups/workspace-voice/desktop-setup.png) · [iPhone flow mockup](docs/mockups/workspace-voice/remote-flow.png) · [Home Screen widget mockup](docs/mockups/workspace-voice/ios-widget.png) · [WebRTC license](docs/third-party/webrtc-license.txt)
