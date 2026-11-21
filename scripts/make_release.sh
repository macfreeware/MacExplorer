#!/bin/bash
# Sürüm dosyalarını hazırlar: evrensel (arm64 + x86_64) uygulama, build/release/MacExplorer.zip ve özeti
# build/release/MacExplorer.zip.sha256. Uygulamanın kendi kendini güncellemesi bu iki sabit adı arar (bkz. Updater.swift).
#
#   scripts/make_release.sh                       # yalnızca dosyaları hazırlar (deneme; imza türü denetlenmez)
#   scripts/make_release.sh --publish notlar.md   # Apple onayı (notarization) + GitLab'da v<sürüm> sürümü (glab ile)
#
# Yayımlama Developer ID ile yapılır (ayrıntılar RELEASING.md'de):
#   SIGN_IDENTITY="Developer ID Application: Ad Soyad (TAKIMKİMLİĞİ)"   # security find-identity -v -p codesigning
#   NOTARY_PROFILE="macexplorer-notary"                                  # xcrun notarytool store-credentials ile kaydedilen ad
#
# Sürüm numarası scripts/Info.plist'teki CFBundleShortVersionString'den gelir; önce onu yükseltip commit'leyin.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
OUT="build/release"
PUBLISH=0
if [[ "${1:-}" == "--publish" ]]; then
  PUBLISH=1
  NOTES="${2:?Notlar dosyası gerekli: scripts/make_release.sh --publish notlar.md}"
fi

# Yayımlamadan önce, uzun derlemeye girmeden: imza, onay profili, notlar ve depo durumu.
if [[ $PUBLISH == 1 ]]; then
  [[ -s "$NOTES" ]] || { echo "✘ Notlar dosyası yok ya da boş: $NOTES" >&2; exit 1; }
  if [[ "${SIGN_IDENTITY:-}" != "Developer ID Application: "* ]]; then
    echo "✘ SIGN_IDENTITY bir Developer ID Application sertifikası olmalı (RELEASING.md)" >&2
    exit 1
  fi
  IDENTITIES=$(security find-identity -v -p codesigning)
  if ! grep -qF "\"$SIGN_IDENTITY\"" <<<"$IDENTITIES"; then
    echo "✘ Sertifika bu Mac'in Anahtar Zinciri'nde yok: $SIGN_IDENTITY" >&2
    exit 1
  fi
  [[ -n "${NOTARY_PROFILE:-}" ]] || { echo "✘ NOTARY_PROFILE gerekli (xcrun notarytool store-credentials)" >&2; exit 1; }
  [[ "$(git symbolic-ref --short HEAD)" == "main" ]] || { echo "✘ main dalında değilsiniz" >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "✘ Commit'lenmemiş değişiklik var" >&2; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "✘ Yerel main, GitLab'daki main ile aynı değil (push / pull)" >&2; exit 1; }
  if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null; then
    echo "✘ v$VERSION zaten var; scripts/Info.plist'te sürümü yükseltin" >&2
    exit 1
  fi
fi

UNIVERSAL=1 scripts/build_app.sh release
rm -rf "$OUT"
mkdir -p "$OUT"

# Apple onayı: Apple'a gönderilir, onaylanınca bilet uygulamaya iliştirilir (staple). Böylece kullanıcıda macOS
# "doğrulanamadı" uyarısı çıkmaz, çevrimdışıyken de.
if [[ $PUBLISH == 1 ]]; then
  echo "▸ Apple onayına gönderiliyor (birkaç dakika sürebilir)…"
  ditto -c -k --norsrc --noextattr --keepParent build/MacExplorer.app "$OUT/notarize.zip"
  NOTARY=$(xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$NOTARY"
  if ! grep -q "status: Accepted" <<<"$NOTARY"; then
    echo "✘ Apple onayı alınamadı. Ayrıntı: xcrun notarytool log <id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
  fi
  rm -f "$OUT/notarize.zip"
  xcrun stapler staple build/MacExplorer.app
fi

# --norsrc --noextattr: macOS'un com.apple.provenance özniteliği zip'e "._" dosyaları olarak girmesin.
ditto -c -k --norsrc --noextattr --keepParent build/MacExplorer.app "$OUT/MacExplorer.zip"
(cd "$OUT" && shasum -a 256 MacExplorer.zip > MacExplorer.zip.sha256)

# Denetim: açılan kopya imzalı ve doğru sürümde mi?
CHECK=$(mktemp -d)
ditto -x -k "$OUT/MacExplorer.zip" "$CHECK"
codesign --verify --deep --strict "$CHECK/MacExplorer.app"
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CHECK/MacExplorer.app/Contents/Info.plist")" == "$VERSION" ]]
# Denetimler çıktıyı önce değişkene alır: pipefail altında grep -q erken çıkınca sol taraf SIGPIPE ile başarısız sayılır.
SIGNATURE=$(codesign -dvv "$CHECK/MacExplorer.app" 2>&1)
if [[ $PUBLISH == 1 ]]; then
  # İmza hep aynı Developer ID'den olmalı: macOS Gizlilik izinlerini imzaya bağlar, imza değişirse izinler yeniden sorulur.
  if ! grep -qF "Authority=$SIGN_IDENTITY" <<<"$SIGNATURE" || ! grep -q "runtime" <<<"$SIGNATURE"; then
    echo "✘ Uygulama $SIGN_IDENTITY ve hardened runtime ile imzalı değil" >&2
    exit 1
  fi
  xcrun stapler validate "$CHECK/MacExplorer.app"
  GATEKEEPER=$(spctl --assess --type execute -vv "$CHECK/MacExplorer.app" 2>&1) || true
  if ! grep -q "source=Notarized Developer ID" <<<"$GATEKEEPER"; then
    echo "$GATEKEEPER" >&2
    echo "✘ Gatekeeper uygulamayı onaylı Developer ID olarak görmüyor" >&2
    exit 1
  fi
else
  echo "ℹ Deneme: imza → $(grep '^Authority=' <<<"$SIGNATURE" | head -1 || echo 'ad-hoc')"
fi
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

if [[ $PUBLISH == 1 ]]; then
  glab release create "v$VERSION" \
    "$OUT/MacExplorer.zip#MacExplorer.zip" \
    "$OUT/MacExplorer.zip.sha256#MacExplorer.zip.sha256" \
    --ref main --name "MacExplorer $VERSION" --notes-file "$NOTES"
fi
