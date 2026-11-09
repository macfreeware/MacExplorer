#!/bin/bash
# Sürüm dosyalarını hazırlar: evrensel (arm64 + x86_64) uygulama, build/release/MacExplorer.zip ve özeti
# build/release/MacExplorer.zip.sha256. Uygulamanın kendi kendini güncellemesi bu iki sabit adı arar (bkz. Updater.swift).
#
#   scripts/make_release.sh                       # yalnızca dosyaları hazırlar
#   scripts/make_release.sh --publish notlar.md   # ayrıca GitLab'da v<sürüm> sürümünü oluşturur (glab ile)
#
# Sürüm numarası scripts/Info.plist'teki CFBundleShortVersionString'den gelir; önce onu yükseltip commit'leyin.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
OUT="build/release"

UNIVERSAL=1 scripts/build_app.sh release
rm -rf "$OUT"
mkdir -p "$OUT"
# --norsrc --noextattr: macOS'un com.apple.provenance özniteliği zip'e "._" dosyaları olarak girmesin.
ditto -c -k --norsrc --noextattr --keepParent build/MacExplorer.app "$OUT/MacExplorer.zip"
(cd "$OUT" && shasum -a 256 MacExplorer.zip > MacExplorer.zip.sha256)

# Denetim: açılan kopya imzalı ve doğru sürümde mi?
CHECK=$(mktemp -d)
ditto -x -k "$OUT/MacExplorer.zip" "$CHECK"
codesign --verify --deep --strict "$CHECK/MacExplorer.app"
# Ad-hoc imzalı sürüm yayımlanmasın: kullanıcıların Gizlilik izinleri güncellemeyle kaybolur.
# Denetimler çıktıyı önce değişkene alır: pipefail altında grep -q erken çıkınca sol taraf SIGPIPE ile başarısız sayılır.
SIGNATURE=$(codesign -dvv "$CHECK/MacExplorer.app" 2>&1)
if ! grep -q "^Authority=freeware2 Code Signing$" <<<"$SIGNATURE"; then
  echo "✘ Uygulama freeware2 sertifikasıyla imzalı değil (scripts/make_signing_cert.sh)" >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CHECK/MacExplorer.app/Contents/Info.plist")" == "$VERSION" ]]
rm -rf "$CHECK"

LISTING=$(unzip -l "$OUT/MacExplorer.zip")
if grep -q '/\._\|__MACOSX' <<<"$LISTING"; then
  echo "✘ Zip'te ._ dosyaları var" >&2
  exit 1
fi

# Deneme ayarları (yalnızca DEBUG) yayımlanan ikilide olmamalı.
BINARY_STRINGS=$(strings build/MacExplorer.app/Contents/MacOS/MacExplorer)
if grep -q "MACEXPLORER_UPDATE_" <<<"$BINARY_STRINGS"; then
  echo "✘ Yayım ikilisinde deneme ayarı var" >&2
  exit 1
fi

echo "✔ $OUT/MacExplorer.zip ($VERSION)"
cat "$OUT/MacExplorer.zip.sha256"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES="${2:?Notlar dosyası gerekli: scripts/make_release.sh --publish notlar.md}"
  glab release create "v$VERSION" \
    "$OUT/MacExplorer.zip#MacExplorer.zip" \
    "$OUT/MacExplorer.zip.sha256#MacExplorer.zip.sha256" \
    --ref main --name "MacExplorer $VERSION" --notes-file "$NOTES"
fi
