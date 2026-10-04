#!/bin/bash
# Builds the app and the installer disk image: the app, an Applications shortcut, and the README.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
rm -rf build/dmg build/OpenClaw-Access.dmg
mkdir -p build/dmg
cp -R 'build/OpenClaw Access.app' build/dmg/
ln -s /Applications build/dmg/Applications
cp README.md 'build/dmg/Read Me.md'
hdiutil create -quiet -volname 'OpenClaw Access' -srcfolder build/dmg -ov -format UDZO build/OpenClaw-Access.dmg
hdiutil verify -quiet build/OpenClaw-Access.dmg
shasum -a 256 build/OpenClaw-Access.dmg
