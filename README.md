# IPAVault — SideStore Anisette + Native ipatool Engine + Deleted Apps

Нативное SwiftUI iOS-приложение (без единой внешней сторонней SPM-зависимости) с официальными серверами **SideStore Anisette**, нативным FairPlay SAP / `kbsync` ядром `ipatool` (`libunicorn.a` + `libWaffleSAP.a`) и прямым поиском/выгрузкой **удалённых из App Store приложений по числовому App ID (`adamId`)**.

## Почему это гарантированно собирается на `macos-15` (Xcode 16)

- **0 внешних Swift Package Manager зависимостей** — полностью убраны `PartyUI` (требовавший Xcode 26 / Swift 6.2), `Telegraph`, `OpenSSL`, `Zip`, `ZsignSwift` и `ApplePackage`. Ошибки `Could not resolve package dependencies (exit code 74)` больше физически невозможны.
- Локальный пакет `MapleSAP` (`swift-tools-version: 5.9`) + нативные библиотеки `libunicorn.a` (Unicorn 2.1.4 TCI) и `libWaffleSAP.a` (`majd/ipatool@3411d57`) собираются на стандартном **`macos-15`** через `cmake`, `go` и `xcodegen`.

## Как работает вход и выгрузка удалённых IPA

1. **SideStore Anisette + авто-failover**
   - Загружает актуальный список серверов из официального `SideStore/anisette-servers/main/servers.json` (плюс встроенный резервный список `ani.idevicehacked.com`, `ani.neoarz.com`, `ani3server.fly.dev`, `ani.jaydenha.uk`, `ani.sidestore.io` и поле для своего URL).
   - Кнопка **«Проверить Anisette сервер»** проверяет живые заголовки (`X-Apple-I-MD`, `X-Apple-I-MD-M`, `X-Apple-I-MD-RINFO`) и задержку в миллисекундах.
   - При входе прикрепляет SideStore Anisette заголовки (`X-Apple-AMD`, `X-Apple-AMD-M`, `X-MMe-Client-Info`, `X-Mme-Device-Id`) вместе с нативной FairPlay SAP подписью (`X-Apple-ActionSignature`).
2. **Прямой поиск удалённых приложений по App ID**
   - Обходит публичный каталог App Store (`itunes.apple.com/lookup`), выполняет 4-ступенчатый каскад Apple:
     `ent/download (kbsync)` → `p{pod}-buy volumeStoreDownloadProduct` → Bag `redownloadProduct` → Bag `updateProduct`.
   - Показывает реальное название, `Bundle ID` и **полный список всех исторических `externalVersionId`** с фильтром и загрузкой в 1 клик.
3. **Готовый IPA без блокировки FairPlay**
   - Нативный упаковщик `WafflePrepareIPA` проверяет MD5, инжектит `iTunesMetadata.plist` и `SC_Info/*.sinf` и сохраняет готовый `.ipa` в `Documents/Downloads` (виден через Share Sheet и приложение «Файлы» на iPhone).

## Сборка `.ipa` на GitHub Actions (без Mac)

1. Распакуйте `IPAVault-SideStoreAnisette.zip` и отправьте в ветку `main` вашего репозитория:
   ```bash
   unzip IPAVault-SideStoreAnisette.zip -d IPAVault
   cd IPAVault
   git init -b main
   git add .
   git commit -m "IPAVault: SideStore Anisette + native ipatool + deleted apps"
   git remote add origin https://github.com/ВАШ_ЛОГИН/IPAVault.git
   git push -u origin main --force
   ```
2. Откройте **Actions → Build IPAVault (SideStore Anisette + Native ipatool)**.
3. Через 4–6 минут в **Artifacts** появится **`IPAVault-SideStoreAnisette-unsigned-ipa`**.
