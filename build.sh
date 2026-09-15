#!/bin/sh
# Build Nit and install a signed copy into /Applications.
#
# Signing: uses $DEVELOPMENT_TEAM if set, else the team of the first codesigning
# identity in the keychain, else falls back to ad-hoc (works, but Accessibility
# permission won't persist across rebuilds — see README).
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
}
xcodegen generate

# Prefer $DEVELOPMENT_TEAM, then the OU (real Team ID) on the first Apple Development
# cert. The 10-char id in the certificate CN is NOT the team id.
TEAM=${DEVELOPMENT_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -1)}
if [ -n "$TEAM" ]; then
  echo "Signing with team $TEAM"
  SIGN="DEVELOPMENT_TEAM=$TEAM"
else
  echo "warning: no codesigning identity found — using ad-hoc signing." >&2
  SIGN="CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES"
fi

xcodebuild -project Nit.xcodeproj -scheme Nit -configuration Release \
  -derivedDataPath build $SIGN build

APP=build/Build/Products/Release/Nit.app
[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

# Replace any running copy, then install with ditto (preserves the signature).
pkill -x Nit 2>/dev/null || true
rm -rf /Applications/Nit.app
ditto "$APP" /Applications/Nit.app

echo "Installed /Applications/Nit.app — launching."
open /Applications/Nit.app
