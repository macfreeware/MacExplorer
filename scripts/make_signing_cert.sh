#!/bin/bash
# Kendinden imzalı kod imzalama sertifikasını oluşturup giriş Anahtar Zinciri'ne ekler (bir kez çalıştırılır).
# build_app.sh bu sertifika varsa onunla imzalar. Böylece macOS, Gizlilik izinlerini (İndirilenler, Tam Disk Erişimi …)
# sürümden sürüme korur; ad-hoc imzada her derleme yeni bir uygulama sayılır.
# Özel anahtar yalnızca Anahtar Zinciri'nde kalır, depoya girmez. Kaybolursa yenisi üretilir; izinler bir kez daha sorulur.
# Sertifikaya güven verilmez: imzalamak için gerekmez, Gatekeeper davranışı da değişmez.
set -euo pipefail

NAME="freeware2 Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✔ Sertifika zaten var: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
[[ -n "$WORK" && -d "$WORK" ]]
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# Sistemdeki LibreSSL: Homebrew OpenSSL 3'ün PKCS#12 biçimini security okuyamıyor.
SSL=/usr/bin/openssl
"$SSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$("$SSL" rand -hex 16)"
"$SSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -passout "pass:$PASS" -out "$WORK/cert.p12"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "✔ Oluşturuldu: $NAME"
security find-identity -p codesigning | grep "\"$NAME\""
