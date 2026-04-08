#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PaperCat"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the real binary as PaperCat-bin
cp "$SCRIPT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME-bin"

# Compile a small Swift launcher that hides from the dock before elevating.
# This prevents the duplicate dock icon.
cat > /tmp/PaperCatLauncher.swift << 'SWIFT'
import AppKit
import Foundation

// Hide this process from the dock immediately
NSApplication.shared.setActivationPolicy(.accessory)

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let bin = "\(dir)/PaperCat-bin"
let pid = ProcessInfo.processInfo.processIdentifier

// Build the osascript command to launch PaperCat-bin as root
let shellCmd = "PAPERCAT_LAUNCHER_PID=\(pid) exec '\(bin)'"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
task.arguments = ["-e", "do shell script \"\(shellCmd)\" with administrator privileges"]

do {
    try task.run()
    task.waitUntilExit()
} catch {
    fputs("Failed to launch: \(error)\n", stderr)
}

exit(task.terminationStatus)
SWIFT

echo "Compiling launcher..."
swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" /tmp/PaperCatLauncher.swift \
    -framework AppKit -framework Foundation 2>&1
rm /tmp/PaperCatLauncher.swift

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Bundle libusb so the app works without Homebrew
echo "Bundling libusb..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
LIBUSB_SRC=$(readlink -f /opt/homebrew/lib/libusb-1.0.0.dylib)
cp "$LIBUSB_SRC" "$APP_BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"
# Fix the binary to look for libusb in Frameworks/ instead of /opt/homebrew
install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib \
    @executable_path/../Frameworks/libusb-1.0.0.dylib \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME-bin"
# Fix the dylib's own install name
install_name_tool -id @executable_path/../Frameworks/libusb-1.0.0.dylib \
    "$APP_BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"

# Sign with entitlements (ad-hoc)
codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - --entitlements "$SCRIPT_DIR/Entitlements.plist" "$APP_BUNDLE"

echo ""
echo "Built successfully: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
