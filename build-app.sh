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

# Create a launcher script that requests admin privileges for USB access
cat > "$APP_BUNDLE/Contents/MacOS/$APP_NAME" << 'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/PaperCat-bin"

# If already root, just run the binary
if [ "$(id -u)" -eq 0 ]; then
    exec "$BIN"
fi

# Request admin privileges via macOS password dialog
osascript -e "do shell script quoted form of \"$BIN\" with administrator privileges" &
LAUNCHER
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Sign with entitlements (ad-hoc)
codesign --force --sign - --entitlements "$SCRIPT_DIR/Entitlements.plist" "$APP_BUNDLE"

echo ""
echo "Built successfully: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
