# MacExplorer: geliştirme ve sürüm çıkarma

Bu belge sürümü çıkaran geliştirici (Mustafa YILDIRIM) ve onun Claude Code oturumu içindir. Claude Code ile çalışırken
oturumun başında bu dosyayı okutun; kurallar ve adımlar buradadır.

Sürümler **Mustafa'nın Developer ID sertifikasıyla imzalanır ve Apple onayından (notarization) geçer.** GitLab'da
sürümü Mustafa yayımlar; GitHub'daki kopyayı Rafet açar (aşağıda 6. adım).

## Depo ve kurallar

- Ana depo: https://gitlab.com/freeware2/macexplorer (GPL-3.0, public). GitHub'daki
  https://github.com/macfreeware/MacExplorer bir yansıdır: GitLab'daki commit ve etiketler oraya kendiliğinden gider.
  **GitHub'a doğrudan push yapılmaz.**
- Depo herkese açıktır: commit'lere ve dosyalara e-posta adresi, parola, token, anahtar, Apple Team ID ya da özel not
  girmez. Commit'ler GitLab'ın gizli e-postasıyla yapılır (GitLab ▸ Preferences ▸ Emails ▸ commit e-postası olarak
  "private commit email"; `git config user.email` ile bu depoda ayarlanır).
- Commit'e yalnızca amaçlanan dosyalar eklenir: `git add <yol>`; `git add -A` ya da `git add .` kullanılmaz. Öncesinde
  `git status` ve `git diff --cached` ile bakılır.
- `main` üzerinde `git push --force` yapılmaz.
- Arayüz metinleri Türkçe kaynak anahtardır (`String(localized: "…", bundle: .live)`); İngilizcesi
  `Resources/en.lproj`. Yeni metin eklenince `scripts/check_strings.sh` çalıştırılır, eksikler `en` ve `tr` tablolarına
  eklenir.
- Sağ tık menüsü ve komut adları Windows Gezgini'ndeki adlardır (Türkçe / İngilizce Windows).
- Klavye: varsayılan Windows düzeni, Mac düzeni seçilebilir; yeni kısayol iki düzende de ve Klavye Kısayolları
  penceresinde olur.
- Menü simgeleri: macOS 27 menülerdeki SF Symbol simgelerini varsayılan olarak gizler. Yeni sağ tık menüleri
  `MenuSymbol.showAll(in:)` ile biter (bkz. `Sources/MacExplorer/MenuSymbols.swift`).
- Deneme çalıştırmaları (`MACEXPLORER_SNAPSHOT=…`) kullanıcının ayarlarını değiştirmemelidir; ekranda kalıcı uyarı
  pencereleri açan denemelerden kaçının.

## Bir kez yapılacak kurulum

1. **Xcode** (ya da Command Line Tools) ve Swift. Denetim: `swift --version`.
2. **glab** (GitLab komut satırı) ve giriş: `brew install glab`, sonra `glab auth login` (gitlab.com).
   Depoda Maintainer yetkisi gerekir (`main` korumalıdır, yalnızca Maintainer push yapar).
3. **Developer ID Application sertifikası** giriş Anahtar Zinciri'nde olmalı: Xcode ▸ Settings ▸ Accounts ▸ hesabınız ▸
   Manage Certificates ▸ **+** ▸ *Developer ID Application*. ("Apple Development" sertifikası dağıtım için değildir.)
   Tam adını öğrenin:

   ```bash
   security find-identity -v -p codesigning
   ```

   Çıktıdaki `"Developer ID Application: Ad Soyad (TAKIMKİMLİĞİ)"` metni `SIGN_IDENTITY` olarak kullanılır.
4. **Apple onayı için kimlik bilgisi** Anahtar Zinciri'ne kaydedilir. appleid.apple.com'dan bir *uygulamaya özel parola*
   oluşturun, sonra:

   ```bash
   xcrun notarytool store-credentials macexplorer-notary --apple-id <apple-id> --team-id <TAKIMKİMLİĞİ>
   ```

   Parola sorulunca uygulamaya özel parolayı girin. Bundan sonra `NOTARY_PROFILE=macexplorer-notary` yeterlidir;
   parola, Apple ID ve Team ID hiçbir dosyaya, commit'e ya da sohbete yazılmaz.
5. Kolaylık için kabuk ayarına (ör. `~/.zshrc`) ekleyin; depoya **eklemeyin**:

   ```bash
   export SIGN_IDENTITY="Developer ID Application: Ad Soyad (TAKIMKİMLİĞİ)"
   export NOTARY_PROFILE="macexplorer-notary"
   ```

## Her sürümde

1. **Güncel main, temiz çalışma alanı**

   ```bash
   git checkout main && git pull
   git status            # boş olmalı
   ```

2. **Denetimler**

   ```bash
   swift test
   scripts/check_strings.sh
   scripts/build_app.sh release    # build/MacExplorer.app; açıp elle deneyin
   ```

3. **Sürüm numarası.** `scripts/Info.plist` içindeki `CFBundleShortVersionString` yükseltilir (ör. 1.3.11 → 1.3.12;
   karşılaştırma sayısaldır, 1.3.10 > 1.3.9). Yalnızca bu satır değişmelidir:

   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.3.12" scripts/Info.plist
   git diff scripts/Info.plist
   git add scripts/Info.plist && git commit -m "Sürüm 1.3.12"
   git push origin main
   ```

4. **Sürüm notları** depo dışında bir dosyaya yazılır (ör. `/tmp/notlar-1.3.12.md`). Biçim sabittir, çünkü uygulamanın
   güncelleme penceresi notu bu biçime göre ayıklar:

   ```markdown
   ## 1.3.11'den bu yana

   - **Özellik adı**: Kullanıcının gözünden ne değişti, bir iki cümle.
   - **Düzeltme**: Ne bozuktu, artık nasıl.

   ## Kurulum

   1.3.0 ve sonrası kuruluysa güncellemeyi uygulama içinden alabilirsiniz: **MacExplorer ▸ Güncellemeleri Denetle…**
   (Apple Silicon ve Intel, macOS 15 ve üstü.)

   Yeni kurulum için `MacExplorer.zip` dosyasını indirip açın, `MacExplorer.app`'i **Uygulamalar** klasörüne sürükleyin.

   ---

   New since 1.3.11: the same changes in one or two English sentences. Apple Silicon and Intel, macOS 15 or later.
   ```

   - Yenilikler **en üstte** olur: 1.3.10 ve öncesi güncelleme penceresinde notun tamamını gösterir.
   - "Kurulum" ve "Denenecekler" başlıklı bölümler güncelleme penceresinde gösterilmez; diğer `##` bölümleri gösterilir.
   - `---` satırından sonrası İngilizcedir ve `New since` ile başlayan cümle İngilizce arayüzde gösterilir.

5. **Yayımlama**

   ```bash
   scripts/make_release.sh --publish /tmp/notlar-1.3.12.md
   ```

   Betik sırayla şunları yapar ve bir adım tutmazsa durur:
   - Uzun derlemeden önce: `SIGN_IDENTITY` bir Developer ID mi, Anahtar Zinciri'nde var mı, `NOTARY_PROFILE` verilmiş
     mi, `main` temiz ve GitLab'daki `main` ile aynı mı, `v<sürüm>` etiketi henüz yok mu.
   - Evrensel (Apple Silicon + Intel) derleme, hardened runtime ile imza.
   - Apple onayı (`notarytool submit --wait`) ve biletin uygulamaya iliştirilmesi (`stapler staple`).
   - `MacExplorer.zip` ve `MacExplorer.zip.sha256`; açılan kopyada imza, sürüm, onay ve Gatekeeper denetimi.
   - GitLab'da `v<sürüm>` sürümü, iki dosya ekli.

   Dosya adları (`MacExplorer.zip`, `MacExplorer.zip.sha256`) **değiştirilmez**: uygulama içi güncelleme bu adları arar.

   Onay reddedilirse ayrıntı:

   ```bash
   xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"
   ```

6. **Doğrulama ve GitHub kopyası**
   - https://gitlab.com/freeware2/macexplorer/-/releases sayfasında yeni sürüm "Latest" olmalı.
   - Rafet'e haber verin: GitHub'daki release'i (aynı zip, özet ve notlarla) Rafet kendi hesabından açar. Yansı
     release taşımaz, yalnızca kodu ve etiketi taşır.
   - Bir önceki sürümü kullanan bir Mac'te **MacExplorer ▸ Güncellemeleri Denetle…** ile güncellemeyi deneyin.

## İlk Developer ID sürümü (bir kez)

- Önceki sürümler Rafet'in kendinden imzalı "freeware2 Code Signing" sertifikasıyla imzalıydı. İmza değiştiği için bu
  sürüme geçen kullanıcılardan macOS klasör izinlerini ve Tam Disk Erişimi'ni **bir kez daha** ister; sonraki
  sürümlerde izinler korunur. Bunu o sürümün notlarına yazın.
- Hardened runtime ile ilk kez imzalanıyor: yayımlamadan önce SFTP/FTP bağlantısı, SSH ile Terminalde aç, arşivler,
  disk görüntüsü bağlama, MacRAR menüsü, MacNote++ ile açma ve uygulama içi güncelleme elle denenmeli.
- Sürüm doğrulanınca README'deki ve sitedeki "ilk açılışta macOS engeller / Yine de Aç" anlatımları ile
  notlardaki `xattr` satırı kaldırılır (onaylı uygulamada gerekmez). Rafet ile birlikte yapılır.
- Bundan sonra her sürüm aynı Developer ID ile imzalanmalı. Başka bir sertifikayla (ya da freeware2 ile) çıkan bir sürüm
  kullanıcılardan izinleri yeniden istetir; betik bu yüzden Developer ID dışındaki imzayı reddeder.

## Sık karşılaşılanlar

- **"Yerel main, GitLab'daki main ile aynı değil"**: `git pull` ya da `git push origin main`.
- **"v… zaten var"**: `scripts/Info.plist`'teki sürüm yükseltilmemiş.
- **Gatekeeper denetimi tutmuyor**: Onay bileti iliştirilmemiş olabilir; `xcrun stapler validate build/MacExplorer.app`.
- **Derleme numarası** (`CFBundleVersion`) commit sayısından üretilir; elle değiştirilmez.
