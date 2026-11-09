#!/bin/bash
# Resources/en.lproj ya da Resources/tr.lproj içinde karşılığı olmayan arayüz metinlerini listeler.
# Anahtarlar Türkçe kaynak metinlerin kendisidir; derleyici onları Text("…"), Button("…"),
# String(localized: "…") gibi yerlerden çıkarır. Eksik yoksa 0, varsa 1 ile çıkar.
#   KEYS_OUT=dosya  çıkarılan anahtarları (JSON) bu dosyaya da yazar
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Her dosya metinlerini bildirsin diye ayrı klasörde temiz derleme. Çıktı dosyaları kaynak dosyanın adını taşır;
# iki hedefte de PasswordVault.swift olduğundan MacExplorerCore ayrıca, kendi klasörüne derlenir.
rm -rf .build/strings 2>/dev/null || { sleep 1; rm -rf .build/strings; }
mkdir -p "$OUT/core" "$OUT/app"
swift build --target MacExplorerCore --build-path .build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/core" >/dev/null
swift build --product MacExplorer --build-path .build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/app" >/dev/null

python3 -I - "$OUT" Resources "${KEYS_OUT:-}" <<'PY'
import glob, json, os, plistlib, re, subprocess, sys
out, res, keys_out = sys.argv[1], sys.argv[2], sys.argv[3]
keys = set()
for f in glob.glob(os.path.join(out, "*", "*.stringsdata")):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
keys = {k for k in keys if re.search(r"[A-Za-zçğıöşüÇĞİÖŞÜ]{2,}", k)}
if keys_out:
    json.dump(sorted(keys, key=str.casefold), open(keys_out, "w"), ensure_ascii=False, indent=0)

def table(lang):
    """<lang>.lproj/Localizable.strings ve .stringsdict anahtarları."""
    found = set()
    path = os.path.join(res, f"{lang}.lproj", "Localizable.strings")
    if os.path.exists(path):
        text = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                              capture_output=True, text=True, check=True).stdout
        found |= set(json.loads(text))
    path = os.path.join(res, f"{lang}.lproj", "Localizable.stringsdict")
    if os.path.exists(path):
        found |= set(plistlib.load(open(path, "rb")))
    return found

status = 0
for lang in ("en", "tr"):
    missing = sorted(keys - table(lang), key=str.casefold)
    if missing:
        status = 1
        print(f"{lang}: {len(missing)} eksik çeviri")
        for k in missing:
            print("   ", json.dumps(k, ensure_ascii=False))
    else:
        print(f"{lang}: {len(keys)} metnin hepsi var")
sys.exit(status)
PY
