#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-RepoPromptRemote.xcodeproj}"
SCHEME="${SCHEME:-RepoPromptRemote}"
CONFIGURATION="${CONFIGURATION:-Debug}"
XCODE_DESTINATION="generic/platform=iOS"
if [[ -n "${XCODE_DEVICE_ID:-}" ]]; then
  XCODE_DESTINATION="id=$XCODE_DEVICE_ID"
fi
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedData}"

build_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$XCODE_DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${REPOPROMPT_SENTRY_DSN:-}" ]]; then
  build_args+=("REPOPROMPT_SENTRY_DSN=$REPOPROMPT_SENTRY_DSN")
fi

xcodebuild "${build_args[@]}" build
