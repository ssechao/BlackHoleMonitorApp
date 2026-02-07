#!/bin/bash
set -e

APP_NAME="BlackHoleMonitorApp"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Clean and create directories
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Compile CoreML model if exists
if [ -d "BlackHoleMonitorApp/VocalSeparatorMicro.mlpackage" ]; then
    echo "Compiling CoreML model..."
    xcrun coremlcompiler compile BlackHoleMonitorApp/VocalSeparatorMicro.mlpackage "$RESOURCES_DIR"
fi

# Compile
echo "Compiling..."
swiftc -o "$MACOS_DIR/$APP_NAME" \
    -target arm64-apple-macosx13.0 \
    -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
    -parse-as-library \
    -O \
    BlackHoleMonitorApp/BlackHoleMonitorApp.swift \
    BlackHoleMonitorApp/MenuBarView.swift \
    BlackHoleMonitorApp/AudioManager.swift \
    BlackHoleMonitorApp/SpectrumAnalyzerView.swift \
    BlackHoleMonitorApp/OscilloscopeView.swift \
    BlackHoleMonitorApp/VerticalSliderView.swift \
    BlackHoleMonitorApp/DiscoView.swift \
    BlackHoleMonitorApp/SpectrumFloatingWindow.swift \
    BlackHoleMonitorApp/VocalSeparatorAI.swift \
    BlackHoleMonitorApp/OptimizedAudioProcessing.swift \
    BlackHoleMonitorApp/DriftCorrectionTests.swift \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# Copy Info.plist
cp BlackHoleMonitorApp/Info.plist "$CONTENTS_DIR/"

# Copy Demucs server script
if [ -f "ML/demucs_server.py" ]; then
    cp ML/demucs_server.py "$RESOURCES_DIR/"
    echo "Copied demucs_server.py to Resources"
fi

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "Build complete: $APP_BUNDLE"

# Create DMG installer with drag-and-drop to Applications
echo ""
echo "Creating DMG installer..."

DMG_NAME="BlackHoleMonitor"
DMG_DIR="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"

rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"

# Copy app and create Applications symlink
cp -R "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null

rm -rf "$DMG_DIR"

echo "DMG created: $DMG_PATH"
echo ""
echo "To install locally:"
echo "  sudo cp -R $APP_BUNDLE /Applications/"
echo "  open /Applications/$APP_NAME.app"
echo ""
echo "To distribute:"
echo "  Share $DMG_PATH — open it and drag the app to Applications."
