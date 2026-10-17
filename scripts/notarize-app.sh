#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${AUVGIT_SIGN_IDENTITY:?Set AUVGIT_SIGN_IDENTITY to your Developer ID Application identity}"
: "${AUVGIT_NOTARY_PROFILE:?Set AUVGIT_NOTARY_PROFILE to a saved notarytool keychain profile}"
./scripts/build.sh --no-install
AUVGIT_APP="$PWD/.artifacts/AuvGit.app"
codesign --force --options runtime --timestamp --sign "$AUVGIT_SIGN_IDENTITY" "$AUVGIT_APP"
codesign --verify --strict --verbose=2 "$AUVGIT_APP"
ditto -c -k --keepParent "$AUVGIT_APP" "$PWD/.artifacts/AuvGit-notary.zip"
xcrun notarytool submit "$PWD/.artifacts/AuvGit-notary.zip" --keychain-profile "$AUVGIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$AUVGIT_APP"
xcrun stapler validate "$AUVGIT_APP"
spctl --assess --type execute --verbose=2 "$AUVGIT_APP"
ditto -c -k --keepParent "$AUVGIT_APP" "$PWD/.artifacts/AuvGit-release.zip"
print "Signed, notarized and stapled: $PWD/.artifacts/AuvGit-release.zip"
