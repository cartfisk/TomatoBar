#!/bin/bash
# Build an ad-hoc signed, universal TomatoBar release candidate from a git ref
# and copy the zip to a destination directory (e.g. a mounted network share).
#
# Usage: scripts/build-rc.sh <version> [ref] [dest]
#   version  MARKETING_VERSION and zip name, e.g. 3.0-rc5
#   ref      git ref to build (default: origin/main, fetched first)
#   dest     directory to copy the zip into (default: /Volumes/data/build)
set -euo pipefail

version=${1:?usage: scripts/build-rc.sh <version> [ref] [dest]}
ref=${2:-origin/main}
dest=${3:-/Volumes/data/build}
zip_name="TomatoBar-$version.zip"

# xcode-select may point at the Command Line Tools, which can't run xcodebuild.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
[ -d "$dest" ] || { echo "error: $dest does not exist (share not mounted?)" >&2; exit 1; }
[ ! -e "$dest/$zip_name" ] || { echo "error: $dest/$zip_name already exists" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Build from an exported tree so the working copy and branch are untouched,
# and from a fresh derived data dir so no stale products end up in the app.
git -C "$repo" fetch origin --quiet
commit=$(git -C "$repo" rev-parse --short "$ref")
echo "Building $version from $ref ($commit)"
mkdir "$work/src"
git -C "$repo" archive "$ref" | tar -x -C "$work/src"

# Xcode 27 no longer supports the project's 11.0 deployment target.
(cd "$work/src" && xcodebuild build -quiet \
    -project TomatoBar.xcodeproj -scheme TomatoBar -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/build" \
    MARKETING_VERSION="$version" MACOSX_DEPLOYMENT_TARGET=12.0 ONLY_ACTIVE_ARCH=NO)

app="$work/build/Build/Products/Release/TomatoBar.app"

# LaunchAtLogin's copy-helper script edits the helper's Info.plist after it is
# signed, which breaks the nested signature; re-sign helper, then the app.
codesign --force --sign - --preserve-metadata=entitlements,identifier,flags \
    "$app/Contents/Library/LoginItems/LaunchAtLoginHelper.app"
codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$app"
codesign --verify --deep --strict "$app"

ditto -c -k --keepParent "$app" "$work/$zip_name"
/bin/cp -n "$work/$zip_name" "$dest/"

local_sum=$(shasum -a 256 "$work/$zip_name" | cut -d' ' -f1)
dest_sum=$(shasum -a 256 "$dest/$zip_name" | cut -d' ' -f1)
[ "$local_sum" = "$dest_sum" ] || { echo "error: checksum mismatch after copy" >&2; exit 1; }

echo "Archs:  $(lipo -archs "$app/Contents/MacOS/TomatoBar")"
echo "Copied: $dest/$zip_name ($local_sum)"
