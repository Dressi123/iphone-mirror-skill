#!/bin/zsh
# Builds bin/iphone-hid against Xcode's private CoreDevice framework, through the hand-written
# interface in hid/. Records the framework version it was built for, so `iphone` rebuilds it
# after an Xcode update instead of calling into a framework that moved underneath it.
cd "${0:A:h}"
FRAMEWORKS=/Library/Developer/PrivateFrameworks
PLIST=$FRAMEWORKS/CoreDevice.framework/Versions/A/Resources/Info.plist
rm -f bin/iphone-hid bin/iphone-hid.version
[[ -f $PLIST ]] || exit 1
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -parse-as-library -Onone -I hid -F $FRAMEWORKS -framework CoreDevice -framework CoreDeviceUtilities \
  -Xlinker -rpath -Xlinker $FRAMEWORKS hid/iphone-hid.swift -o bin/iphone-hid.tmp || exit 1
mv bin/iphone-hid.tmp bin/iphone-hid
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST > bin/iphone-hid.version
