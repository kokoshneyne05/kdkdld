# WaffleStore + Deleted Apps (Unsigned IPA Builder)

Автоматическая сборка неподписанного `.ipa` на базе рабочего Apple ID логина **nxtcoreee3/WaffleStore** (Unicorn TCI + MapleSAP + `WaffleSAPKBSync`) с добавленным модулем прямого поиска и выгрузки **удалённых из App Store приложений по числовому App ID (`adamId`)**.

## Что объединено

1. **Авторизация Apple ID (100% из WaffleStore без изменений)**
   - Используется оригинальный движок `MapleSAP` + нативные библиотеки `libunicorn.a` и `libWaffleSAP.a` (компилируются автоматически из исходников при сборке).
   - Полностью сохранён рабочий вход, 2FA, Keychain-сессия и генерация `kbsync`.
2. **Прямой поиск и выгрузка удалённых приложений по App ID**
   - Обход публичного каталога (`itunes.apple.com/lookup` и `uclient-api/.../lookup`), которые возвращают пустоту для удалённых приложений.
   - Автоматический 4-ступенчатый каскад Apple:
     `ent/download (kbsync)` → `p{pod}-buy volumeStoreDownloadProduct` → Bag `redownloadProduct` → Bag `updateProduct`.
   - Разбор ответа Apple напрямую по `itemId` без предварительного знания `bundleId` и версии (`StoreParsing.downloadDirect`) — из ответа извлекаются реальное название, `Bundle ID`, все исторические `externalVersionId` и SINF.
   - Авто-переключение: если обычный `Downgrade App` не находит ID в каталоге App Store, он сам переключается в режим удалённого приложения; также доступна отдельная кнопка **«Найти удалённое по ID (без каталога)»**.
   - Поддержка ручного ввода конкретного `External Version ID` (если нужно выгрузить конкретную старую сборку).
3. **Сохранение и экспорт FairPlay IPA без блокировки**
   - В оригинальном WaffleStore FairPlay-зашифрованные `.ipa` (все официальные приложения из App Store) удалялись сразу после скачивания, если не включена скрытая опция `Risky Options`.
   - Патч убирает удаление файла: собранный `.ipa` с инжектированными `iTunesMetadata.plist` и `SC_Info/*.sinf` всегда сохраняется в `Documents/Downloads` и готов к отправке через **Export IPA** или через приложение «Файлы» на iPhone.

## Как собрать `.ipa` через GitHub Actions (бесплатно, без Mac)

1. Создайте новый репозиторий на GitHub (например, `WaffleStore-DeletedApps`).
2. Распакуйте скачанный архив и загрузите файлы в ветку `main`:
   ```bash
   unzip WaffleStore-DeletedApps.zip -d WaffleStore-DeletedApps
   cd WaffleStore-DeletedApps
   git init -b main
   git add .
   git commit -m "WaffleStore + Deleted Apps builder"
   git remote add origin https://github.com/ВАШ_ЛОГИН/WaffleStore-DeletedApps.git
   git push -u origin main --force
   ```
3. Откройте вкладку **Actions → Build WaffleStore + Deleted Apps IPA → Run workflow** (или дождитесь автозапуска после `git push`).
4. Через 5–8 минут (компиляция `libunicorn.a` + `libWaffleSAP.a` + `WaffleStore`) в разделе **Artifacts** появится архив **`WaffleStore-DeletedApps-unsigned-ipa`** с готовым `WaffleStore-DeletedApps-unsigned.ipa`.

## Как выгружать удалённые приложения на iPhone

1. Установите `WaffleStore-DeletedApps-unsigned.ipa` через TrollStore, SideStore, AltStore, Sideloadly или LiveContainer.
2. Войдите в свой Apple ID (того аккаунта, на котором приложение когда-то было скачано/куплено — со значком облачка в истории покупок).
3. В поле ввода укажите числовой App ID (например, `310633997`) или ссылку App Store.
4. При желании укажите конкретный `External Version ID` во втором поле, либо оставьте его пустым для выбора из всего списка исторических версий.
5. Нажмите **«Найти удалённое по ID (без каталога)»** → выберите нужную версию → дождитесь скачивания и нажмите **Export IPA**.
