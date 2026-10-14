# MakeRetroShareRPM.sh

Собирает RPM-пакет [RetroShare](https://retroshare.cc) для Fedora (Qt6, OpenSSL 3.x) из git-исходников. Результат: пакет, который ставится через `dnf`, регистрируется в системе (ярлык, иконки) и запускается командой `retroshare`.

## Быстрый старт

```bash
./MakeRetroShareRPM.sh                    # master
RS_REF=v0.6.7.3 ./MakeRetroShareRPM.sh    # тег, ветка или хеш коммита
sudo dnf install _rpmbuild/RPMS/x86_64/retroshare-*.rpm
retroshare
```

Нужны Fedora, `sudo` и доступ к GitHub. Скрипт сам ставит `rpm-build`, `git`, `tar`, `gzip`, а затем все BuildRequires командой `dnf builddep` по сгенерированному spec.

## Что делает скрипт

1. **Инструменты.** Устанавливает то, что нужно самому скрипту.
2. **Исходники.** Клонирует репозиторий, переключается на `RS_REF`, разворачивает submodules и упаковывает всё в `Source0` (tar.gz). Архив собирается вручную: в архивах GitHub нет submodules, а без них RetroShare не собирается. Архив детерминирован: порядок файлов, владелец, mtime и заголовок gzip зафиксированы.
3. **Вспомогательные файлы.** Создаёт обёртку запуска, конфиг OpenSSL и `.desktop`-файл (Source1–Source3).
4. **Spec.** Генерирует `retroshare.spec` из шаблона и ставит BuildRequires.
5. **Сборка.** `rpmbuild -ba`; лог в `_logs/rpmbuild.log`. Число потоков выбирается по свободной памяти (LTO требует около 2 ГБ на процесс компилятора).
6. **Проверка.** Убеждается, что в пакете есть обёртка, бинарник, конфиг, ярлык и иконка; запускает `rpmlint`, если он установлен.

### Версия пакета

- Сборка из тега: `Version` = тег, `Release` = `1`.
- Сборка из ветки или коммита: `Version` = ближайший тег, `Release` = `1.<дата>git<хеш>` (post-release snapshot по Fedora Packaging Guidelines).

### Что получается

| Пакет | Назначение |
|---|---|
| `retroshare` | Основной. Только он нужен для работы |
| `retroshare-debuginfo`, `retroshare-debugsource` | Символы и исходники для gdb, ABRT, coredumpctl. Создаются автоматически; `RS_NODEBUG=1` отключает |
| `retroshare-*.src.rpm` | SRPM в `_rpmbuild/SRPMS/` |

Исходники RetroShare не патчатся. Единственная правка в `%prep` — замена заглушки `[version not available]` в `.pro`/`.pri` на хеш коммита: в tarball нет `.git`, а заглушка содержит пробелы и недопустима в значении `-D…`.

### Переменные окружения

| Переменная | Значение |
|---|---|
| `RS_REF` | ветка, тег или хеш коммита (по умолчанию `master`) |
| `RS_VERSION` | принудительная `Version` |
| `RS_WORKDIR` | рабочий каталог (по умолчанию каталог скрипта) |
| `RS_JOBS` | число потоков сборки |
| `RS_NODEBUG=1` | не создавать debuginfo/debugsource |
| `SKIP_DEPS=1` | не вызывать `dnf` |
| `FORCE_RECLONE=1` | удалить и заново склонировать исходники |
| `RPM_CHANGELOG_WHO` | `Имя <email>` для `%changelog` |

## Почему бинарник запускается через обёртку

RetroShare использует SHA-1 в сертификатах и подписях, в том числе в уже существующих у пользователей. В Fedora с OpenSSL 3 это не работает «из коробки»:

- OpenSSL 3 отвергает SHA-1 уже на уровне безопасности `SECLEVEL=1`, а политика Fedora по умолчанию строже;
- Fedora дополнительно ограничивает SHA-1 подписи через `crypto-policies`.

Снизить требования для всей системы (`update-crypto-policies --set LEGACY`) нельзя без ослабления остальных программ. Править код RetroShare тоже не нужно: он совместим с API OpenSSL 1.1+/3. Поэтому настройка делается **окружением одного процесса**.

### Раскладка

```
/usr/bin/retroshare                 обёртка (sh-скрипт)
/usr/bin/retroshare-service         симлинк на обёртку (если собран)
/usr/libexec/retroshare/retroshare  настоящий бинарник
/etc/retroshare/openssl-rs.cnf      конфиг OpenSSL для RetroShare
```

Обёртка выбирает бинарник по собственному имени (`${0##*/}`), поэтому один скрипт обслуживает и `retroshare`, и `retroshare-service`. Бинарник лежит в `libexec`, потому что `/usr/bin` занят обёрткой; сборка проверяет, что upstream не положил туда свой файл.

### Что задаёт обёртка

| Переменная | Эффект |
|---|---|
| `OPENSSL_ENABLE_SHA1_SIGNATURES=1` | Даунстрим-переменная OpenSSL в Fedora/RHEL (в upstream OpenSSL её нет): разрешает SHA-1 подписи |
| `OPENSSL_CONF=/etc/retroshare/openssl-rs.cnf` | `SECLEVEL=0`, `MinProtocol=TLSv1.2`, провайдер `default` |

Уже заданные пользователем значения обёртка не перезаписывает.

### Ограничения

- Для процесса RetroShare `openssl-rs.cnf` **полностью заменяет** системный `openssl.cnf`, включая crypto-policies. Остальные программы не затронуты.
- Переменные окружения наследуют процессы, запущенные из RetroShare.
- Конфиг помечен `%config(noreplace)`: локальные правки сохраняются при обновлении пакета.
- Запуск напрямую (`/usr/libexec/retroshare/retroshare`) обходит настройку, и SHA-1 снова будет отвергаться.

## Ярлык и иконки

Ярлык ставит spec, а не `make install`: upstream-файл не проходит `desktop-file-validate` (устаревший ключ `Encoding`, иконка с расширением, абсолютный путь в `Exec`, `Categories` без завершающей `;`). Собственный файл устанавливается через `desktop-file-install`, который его проверяет и при ошибке прерывает сборку. Растровые иконки hicolor ставит upstream, SVG — spec. Окно RetroShare имеет `app_id` `retroshare`, совпадающий с именем `.desktop`, поэтому GNOME связывает окно с ярлыком без `StartupWMClass`.

## Известные ограничения сборки

- Выражение `License` в spec составлено вручную и сканером не проверялось; перед публикацией пакета сверьте его (например, `licensecheck -r`).
- Библиотеки librnp, restbed, libsam3 и udp-discovery-cpp линкуются статически из `supportlibs` (отражено в `Provides: bundled(...)`).
- Флаг `-Wno-template-body` отключает диагностику GCC 16 для встроенного rapidjson в плагинах; исходники не меняются.

## Удаление

```bash
sudo dnf remove retroshare retroshare-debuginfo retroshare-debugsource
```
