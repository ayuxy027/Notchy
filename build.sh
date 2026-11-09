#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p Notchy.app/Contents/MacOS
swiftc -O Notchy.swift KeySounds.swift -o Notchy.app/Contents/MacOS/Notchy
cat > Notchy.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Notchy</string>
  <key>CFBundleIdentifier</key><string>com.ayux.notchy</string>
  <key>CFBundleName</key><string>Notchy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
EOF
rm -rf Notchy.app/Contents/Resources/Packs && mkdir -p Notchy.app/Contents/Resources && cp -R Packs Notchy.app/Contents/Resources/
KC="$HOME/Library/Keychains/notchy-signing.keychain-db"; KCPW=notchy; ID="Notchy Local Signing"
if [ ! -f "$KC" ]; then
  T=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$ID" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:$KCPW 2>/dev/null \
    || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:$KCPW
  security create-keychain -p $KCPW "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p $KCPW "$KC"
  security import "$T/id.p12" -k "$KC" -P $KCPW -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k $KCPW "$KC" >/dev/null
  rm -rf "$T"
fi
security unlock-keychain -p $KCPW "$KC"
codesign --force --keychain "$KC" -s "$ID" -i com.ayux.notchy Notchy.app
echo "Built $(pwd)/Notchy.app"

pkill -x Notchy || true
rm -rf /Applications/Notchy.app && ditto Notchy.app /Applications/Notchy.app

AGENT="$HOME/Library/LaunchAgents/com.ayux.notchy.plist"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ayux.notchy</string>
  <key>Program</key><string>/Applications/Notchy.app/Contents/MacOS/Notchy</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/com.ayux.notchy 2>/dev/null || true
while launchctl print gui/$(id -u)/com.ayux.notchy >/dev/null 2>&1; do sleep 0.2; done
launchctl bootstrap gui/$(id -u) "$AGENT"
echo "Notchy (re)started via launchd"
