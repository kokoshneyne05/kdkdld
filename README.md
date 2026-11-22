# IPAVault v2 — Нативный iOS IPA Downloader (FairPlay SAP + 2FA)

Нативное iOS-приложение на SwiftUI для стабильного входа в Apple ID (с криптографической подписью **FairPlay SAP / `X-Apple-ActionSignature`** и 2FA), выгрузки **удалённых из App Store** купленных приложений по App ID (`adamId`) и версиям (`externalVersionId`), а также встроенной диагностикой сети.

## Возможности v2
- **Настоящая подпись FairPlay SAP (`X-Apple-ActionSignature`):** устраняет пустые ответы `HTTP 204 / 403` от серверов Apple благодаря динамическому `bag.xml`, двухшаговому рукопожатию SAP (`setupCert.plist` → `signSapSetup/legacy`), постоянному Device GUID в Keychain и сохранению живой SAP-сессии с куками при вводе 6-значного кода 2FA.
- **Два движка авторизации с переключателем:**
  1. **ApplePackage (SAP + AsyncHTTPClient)** — проверенный эталонный движок по умолчанию.
  2. **URLSession + SAP Bridge** — нативный сетевой стек iOS поверх того же `SAPSigner` (удобен при работе через системный VPN/прокси iPhone).
- **Встроенная панель диагностики на iPhone:** кнопка «Проверить Bag + SAP» (тест соединения и SAP-подписи без ввода пароля), живой журнал HTTP-статусов, заголовков Pod/Storefront и ошибок `failureType` с автоматическим скрытием паролей/токенов и экспортом лога.
- **Трёхуровневая автоцепочка для удалённых приложений:** прямой запрос `volumeStoreDownloadProduct` → автоматический fallback на `redownload` → `updateProduct`, без зависимости от публичного поиска App Store.
- **Валидная сборка `.ipa`:** потоковое скачивание на диск + инжект `iTunesMetadata.plist` и FairPlay `SC_Info/*.sinf` через `SignatureInjector` (`ApplePackage` / `ZIPFoundation`), доступ в «Файлах» и экспорт в TrollStore / SideStore / AltStore.

## Как собрать неподписанный `.ipa` (без Mac и Xcode)

1. Создайте репозиторий на [GitHub](https://github.com/new) (публичный — бесплатные минуты macOS; приватный — в рамках лимита GitHub Free).
2. Распакуйте `IPAVault-iOS.zip` и загрузите **все файлы** в корень репозитория (включая `.github/workflows/build-ipa.yml`).
3. Откройте вкладку **Actions → Build Unsigned IPA → Run workflow**. Сборка идёт на раннере **`macos-26`** (Xcode 26 / Swift 6.2).
4. Через 3–5 минут (при первой сборке компилируются `ApplePackage` и `OpenSSL`) скачайте артефакт **`IPAVault-unsigned-ipa`** и распакуйте `IPAVault-unsigned.ipa`.
5. Установите на iPhone через **TrollStore**, **Sideloadly**, **AltStore**, **SideStore** или **ESign**.
