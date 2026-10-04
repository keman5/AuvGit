#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release
BUILD_BIN_PATH="$(swift build --build-system native -c release --show-bin-path)"
APP="$PWD/.artifacts/RayGit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp "$BUILD_BIN_PATH/RayGit" "$APP/Contents/MacOS/RayGit"
RESOURCE_BUNDLE="$BUILD_BIN_PATH/RayGit_RayGitLocalization.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  print -u2 "Missing localization resource bundle: $RESOURCE_BUNDLE"
  exit 1
fi
# Keep translated resources self-contained in the distributable app.
rm -rf "$APP/Contents/Resources/RayGit_RayGitLocalization.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
TERMINAL_RESOURCE_BUNDLE="$BUILD_BIN_PATH/SwiftTerm_SwiftTerm.bundle"
if [[ ! -d "$TERMINAL_RESOURCE_BUNDLE" ]]; then
  print -u2 "Missing terminal resource bundle: $TERMINAL_RESOURCE_BUNDLE"
  exit 1
fi
rm -rf "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle" "$APP/SwiftTerm_SwiftTerm.bundle"
# SwiftTerm probes Contents/Resources directly without the generated Bundle.module accessor.
cp -R "$TERMINAL_RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>RayGit</string>
<key>CFBundleIdentifier</key><string>dev.raygit.mac</string>
<key>CFBundleName</key><string>RayGit</string>
<key>CFBundleDisplayName</key><string>RayGit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ja</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print "Built $APP"
