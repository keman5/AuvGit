#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${RAYGIT_SIGN_IDENTITY:?Set RAYGIT_SIGN_IDENTITY to your Developer ID Application identity}"
: "${RAYGIT_NOTARY_PROFILE:?Set RAYGIT_NOTARY_PROFILE to a saved notarytool keychain profile}"
./scripts/build-app.sh --no-install
RAYGIT_APP="$PWD/.artifacts/RayGit.app"
codesign --force --options runtime --timestamp --sign "$RAYGIT_SIGN_IDENTITY" "$RAYGIT_APP"
codesign --verify --strict --verbose=2 "$RAYGIT_APP"
ditto -c -k --keepParent "$RAYGIT_APP" "$PWD/.artifacts/RayGit-notary.zip"
xcrun notarytool submit "$PWD/.artifacts/RayGit-notary.zip" --keychain-profile "$RAYGIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$RAYGIT_APP"
xcrun stapler validate "$RAYGIT_APP"
spctl --assess --type execute --verbose=2 "$RAYGIT_APP"
ditto -c -k --keepParent "$RAYGIT_APP" "$PWD/.artifacts/RayGit-release.zip"
print "Signed, notarized and stapled: $PWD/.artifacts/RayGit-release.zip"
