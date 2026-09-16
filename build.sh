#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/arm64 build/x86_64 'build/OpenClaw Access.app/Contents/MacOS'
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -O -target "$arch-apple-macos13.0" App.swift -o "build/$arch/OpenClawAccess"
done
lipo -create build/arm64/OpenClawAccess build/x86_64/OpenClawAccess -output 'build/OpenClaw Access.app/Contents/MacOS/OpenClawAccess'
cp Info.plist 'build/OpenClaw Access.app/Contents/Info.plist'
codesign --force --sign - 'build/OpenClaw Access.app'
codesign --verify --strict 'build/OpenClaw Access.app'
