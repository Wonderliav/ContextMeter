#!/bin/bash
# Builds "ContextMeter Codex.app" next to this script and (re)launches it. macOS 13+, needs Xcode Command Line Tools (xcode-select --install).
# Signing: put a code-signing identity hash in ./signing-id (or CM_SIGN_ID) so macOS keeps Accessibility approval across
# rebuilds and updates. Without one the app is signed ad-hoc and macOS may ask again after each update.
set -e
cd "$(dirname "$0")"
APP="ContextMeter Codex.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/ContextMeter" ContextMeter.swift
ID="${CM_SIGN_ID:-$(cat signing-id 2>/dev/null || true)}"
codesign --force --deep -s "${ID:--}" "$APP"
pkill -f "$PWD/$APP/Contents/MacOS" || true; sleep 1; open "$APP"
