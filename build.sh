#!/bin/zsh
# Compiles iphone.swift to bin/iphone-core. Safe to rerun; `iphone` calls this when stale.
# Also builds bin/iphone-hid, the pointer-free touch helper, where Xcode's private CoreDevice
# framework exists; a failure there never fails the main tool.
set -e
cd "${0:A:h}"
mkdir -p bin
xcrun swiftc -O -swift-version 5 iphone.swift -o bin/iphone.tmp
mv bin/iphone.tmp bin/iphone-core
./build-hid.sh || echo "iphone: pointer-free touches unavailable (bin/iphone-hid did not build)" >&2
