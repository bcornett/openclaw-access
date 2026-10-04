#!/bin/bash
# Clicks through the views offscreen against the test fixture and writes PNGs to build/ui for review. Nothing appears on screen.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ui build/tests
rm -f build/ui/*.png
sed '/@main struct AccessApp/,$d' App.swift > build/ui/AppUI.swift
cp Tests/ui.swift build/ui/main.swift
xcrun swiftc build/ui/AppUI.swift build/ui/main.swift -o build/ui/ui
for scenario in edit type conflict missing dark min; do
  echo "$scenario"
  build/ui/ui "$PWD" "$PWD/build/ui" "$scenario"
done
