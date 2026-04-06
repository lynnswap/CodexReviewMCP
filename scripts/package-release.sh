#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--dist-root <dir>] [--output-dir <dir>]
EOF
}

dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

app_path="$dist_base/arm64/app/CodexReviewMonitor.app"
binary_path="$dist_base/arm64/bin/codex-review-mcp"
app_binary_path="$app_path/Contents/MacOS/CodexReviewMonitor"
archive_path="$output_base/CodexReviewMCP-macos-arm64.zip"

for path in "$app_path" "$binary_path" "$app_binary_path"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing staged artifact: $path" >&2
    exit 1
  fi
done

if [[ "$(lipo -archs "$app_binary_path")" != "arm64" ]]; then
  echo "CodexReviewMonitor.app is not arm64-only." >&2
  exit 1
fi

if [[ "$(lipo -archs "$binary_path")" != "arm64" ]]; then
  echo "codex-review-mcp is not arm64-only." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stage_root="$tmp_dir/CodexReviewMCP"
mkdir -p "$stage_root"
cp -R "$app_path" "$stage_root/CodexReviewMonitor.app"
cp "$binary_path" "$stage_root/codex-review-mcp"
chmod +x "$stage_root/codex-review-mcp"

mkdir -p "$output_base"
rm -f "$archive_path"
ditto -c -k --keepParent "$stage_root" "$archive_path"

echo "Created release archive: $archive_path"
