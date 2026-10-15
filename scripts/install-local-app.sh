#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_SOURCE="${1:-$PWD/.artifacts/AuvGit.app}"
INSTALLED_APP="/Applications/AuvGit.app"
[[ -x "$APP_SOURCE/Contents/MacOS/AuvGit" ]]
codesign --verify --strict "$APP_SOURCE"
if pgrep -f '^/Applications/AuvGit.app/Contents/MacOS/AuvGit([[:space:]]|$)' >/dev/null; then
  print -u2 "Quit AuvGit before installing; the running app has not been changed."
  exit 1
fi
ditto "$APP_SOURCE" "$INSTALLED_APP"
codesign --verify --strict "$INSTALLED_APP"
cmp -s "$APP_SOURCE/Contents/MacOS/AuvGit" "$INSTALLED_APP/Contents/MacOS/AuvGit"
print "Installed and verified $INSTALLED_APP"
