#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_SOURCE="${1:-$PWD/.artifacts/RayGit.app}"
INSTALLED_APP="/Applications/RayGit.app"
[[ -x "$APP_SOURCE/Contents/MacOS/RayGit" ]]
codesign --verify --strict "$APP_SOURCE"
if pgrep -f '^/Applications/RayGit.app/Contents/MacOS/RayGit([[:space:]]|$)' >/dev/null; then
  print -u2 "Quit RayGit before installing; the running app has not been changed."
  exit 1
fi
ditto "$APP_SOURCE" "$INSTALLED_APP"
codesign --verify --strict "$INSTALLED_APP"
cmp -s "$APP_SOURCE/Contents/MacOS/RayGit" "$INSTALLED_APP/Contents/MacOS/RayGit"
print "Installed and verified $INSTALLED_APP"
