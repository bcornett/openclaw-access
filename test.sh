#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
sed '/@MainActor final class Model/,$d' App.swift > build/tests/Core.swift
cp Tests/main.swift build/tests/main.swift
xcrun swiftc build/tests/Core.swift build/tests/main.swift -o build/tests/test
build/tests/test "$PWD/Tests/fixture.py"
