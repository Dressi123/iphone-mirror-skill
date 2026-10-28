#!/bin/zsh
# Compiles iphone.swift to bin/iphone. Safe to rerun; `bin/iphone` calls this when stale.
set -e
cd "${0:A:h}"
mkdir -p bin
xcrun swiftc -O -swift-version 5 iphone.swift -o bin/iphone.tmp
mv bin/iphone.tmp bin/iphone-core
