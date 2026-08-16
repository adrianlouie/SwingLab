#!/bin/bash
# Builds SwingLab and runs its tests in the iOS Simulator.
# Requires full Xcode (see README step 1).
set -e

cd "$(dirname "$0")"

# Fall back to the Xcode app directly if the command line is still pointed at
# the Command Line Tools (switching that permanently needs sudo).
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app
        echo "Note: using /Applications/Xcode.app for this run."
        echo "To make it permanent: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    else
        echo "Xcode is not installed. Get it from the Mac App Store, then run:"
        echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
    fi
fi

# Pick whatever iPhone simulator this Mac actually has.
DEVICE=$(xcrun simctl list devices available \
    | grep -oE 'iPhone [0-9A-Za-z ]+ \(' \
    | head -1 | sed 's/ ($//; s/ (//')
DEVICE=${DEVICE:-iPhone 16}

echo "Building for: $DEVICE"
xcodebuild build \
    -project SwingLab.xcodeproj \
    -scheme SwingLab \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -quiet

echo ""
echo "Running tests..."
xcodebuild test \
    -project SwingLab.xcodeproj \
    -scheme SwingLab \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -quiet

echo ""
echo "Build and tests passed."
