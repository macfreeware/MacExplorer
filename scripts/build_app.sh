#!/bin/bash
# MacExplorer.app paketini üretir.  Kullanım: scripts/build_app.sh [release|debug]
# UNIVERSAL=1 ortam değişkeni ile arm64+x86_64 evrensel ikili üretilir.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "▸ Derleniyor ($CONFIG)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacExplorer"

APP="build/MacExplorer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacExplorer"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Çeviriler: Türkçe kaynak dil, İngilizce çeviri (bkz. scripts/check_strings.sh)
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "▸ Simge üretiliyor…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# Uygulama simgesi Resources/AppIcon.png (1024 px, saydam köşeli; bkz. scripts/make_icon_from_checker.swift); yoksa çizilerek üretilir.
if [[ -f Resources/AppIcon.png ]]; then
  cp Resources/AppIcon.png build/icon_1024.png
else
  swift scripts/make_icon.swift build/icon_1024.png
fi
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

PB=/usr/libexec/PlistBuddy
# Derleme numarası: commit sayısı (git yoksa atlanır).
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  "$PB" -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

# Sabit imza: macOS Gizlilik izinlerini imzaya bağlar; ad-hoc imzada her derleme yeni uygulama sayılır ve izinler yeniden
# sorulur. Sertifika (scripts/make_signing_cert.sh) bu Mac'te yoksa ad-hoc imzalanır; yayımlama bunu reddeder.
SIGN_NAME="freeware2 Code Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  SIGN_IDENTITY="$SIGN_NAME"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
touch "$APP"   # Dock ve Finder simge önbelleği yenilensin
echo "✔ Hazır: $APP"

# build/ içindeki geliştirme kopyası Spotlight/Launch Services'e ikinci bir kopya olarak kaydolmasın.
touch build/.metadata_never_index

# INSTALL=1: /Applications'a kopyalar.
if [[ "${INSTALL:-0}" == "1" ]]; then
  echo "▸ /Applications'a kuruluyor…"
  rm -rf "/Applications/MacExplorer.app"
  cp -R "$APP" "/Applications/MacExplorer.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/MacExplorer.app"
  echo "✔ Kuruldu."
fi
