#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -o build/make-icon scripts/make-icon.swift
rm -rf build/AppIcon.iconset
build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
