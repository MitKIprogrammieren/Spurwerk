#!/bin/bash
# Baut Spurwerk.ipa auf dem Mac (für SideStore/AltStore). Braucht Xcode.
set -e
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild -project Spurwerk.xcodeproj -scheme Spurwerk -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
rm -rf Payload Spurwerk.ipa
mkdir Payload
cp -R build/Build/Products/Release-iphoneos/Spurwerk.app Payload/
zip -qr Spurwerk.ipa Payload
rm -rf Payload
# Gleich in iCloud Drive legen – dann auf dem iPhone in SideStore über „+“ → iCloud Drive auswählen
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [ -d "$ICLOUD" ]; then
  cp Spurwerk.ipa "$ICLOUD/Spurwerk.ipa"
  echo "Fertig: Spurwerk.ipa liegt in iCloud Drive – auf dem iPhone in SideStore über „+“ auswählen."
else
  echo "Fertig: $(pwd)/Spurwerk.ipa – per AirDrop aufs iPhone und in SideStore öffnen."
fi
