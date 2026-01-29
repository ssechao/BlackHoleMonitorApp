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
echo ""
echo "To install, run:"
echo "  cp -R $APP_BUNDLE /Applications/"
echo ""
echo "To launch:"
echo "  open /Applications/$APP_NAME.app"
