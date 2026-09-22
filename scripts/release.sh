#!/bin/zsh
# Builds an unsigned Release copy of Dido and wraps it in a DMG under dist/.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
version=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)
[[ -n "$version" ]] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }

xcodegen generate
xcodebuild -project Dido.xcodeproj -scheme Dido -configuration Release \
  -derivedDataPath build/DerivedData build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO | tail -3

app="build/DerivedData/Build/Products/Release/Dido.app"
[[ -d "$app" ]] || { echo "Build product not found at $app" >&2; exit 1; }

staging="dist/dmg"
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Dido $version" -srcfolder "$staging" -ov -format UDZO "dist/Dido-$version.dmg" >/dev/null
rm -rf "$staging"
echo "Built dist/Dido-$version.dmg"
