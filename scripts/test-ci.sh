#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repo_root/.build/xcode-derived-data"

pushd "$repo_root" >/dev/null

swift test --filter ReviewJobsTests
swift test --filter ReviewCoreTests
swift test --filter ReviewHTTPServerTests
swift test --filter ReviewCLITests
swift test --filter CodexReviewMCPTests
swift test --filter ReviewUITests
swift test --no-parallel --filter ReviewStdioAdapterTests

xcodebuild test \
  -workspace CodexReviewMCP.xcworkspace \
  -scheme CodexReviewMonitor \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

popd >/dev/null
