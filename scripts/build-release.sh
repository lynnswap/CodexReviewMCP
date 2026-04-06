#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]
EOF
}

version=""
dist_root="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi

arch="arm64"
scratch_path="$repo_root/.build/release-$arch"
out_dir="$dist_base/$arch"
bin_out="$out_dir/bin"
app_out="$out_dir/app"
archive_path="$out_dir/CodexReviewMonitor-$version.xcarchive"

pushd "$repo_root" >/dev/null

rm -rf "$out_dir" "$scratch_path"
mkdir -p "$bin_out" "$app_out"

swift build \
  -c release \
  --arch "$arch" \
  --product codex-review-mcp \
  --scratch-path "$scratch_path"

bin_path="$(
  swift build \
    -c release \
    --arch "$arch" \
    --product codex-review-mcp \
    --scratch-path "$scratch_path" \
    --show-bin-path
)"

cp "$bin_path/codex-review-mcp" "$bin_out/codex-review-mcp"
chmod +x "$bin_out/codex-review-mcp"

xcodebuild archive \
  -workspace CodexReviewMCP.xcworkspace \
  -scheme CodexReviewMonitor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath "$archive_path" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

cp -R "$archive_path/Products/Applications/CodexReviewMonitor.app" "$app_out/CodexReviewMonitor.app"

popd >/dev/null

echo "Staged release artifacts at: $out_dir"
