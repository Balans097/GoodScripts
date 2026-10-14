#!/bin/bash
# =============================================================================
# MakeRetroShareRPM.sh — сборка RPM RetroShare для Fedora (Qt6, OpenSSL 3.x)
#
# ПРОЦЕСС (канонический RPM-цикл)
#   1. Исходники  чистый git-checkout + submodules → Source0 (tar.gz).
#                 Архив собирается сами: у GitHub-архивов нет submodules,
#                 а RetroShare без них не собирается. Архив детерминирован
#                 (порядок файлов, владелец, mtime, gzip -n).
#   2. Spec       генерируется из шаблона; %prep / %build / %install / %files.
#                 BuildRequires ставит `dnf builddep` по самому spec.
#   3. rpmbuild -ba → бинарные пакеты + SRPM.
#
# КАКИЕ ПАКЕТЫ ПОЛУЧАЮТСЯ
#   В spec описан один пакет — retroshare. Ещё два (retroshare-debuginfo и
#   retroshare-debugsource) rpmbuild создаёт сам: макрос %debug_package из
#   redhat-rpm-config после %install отделяет отладочные символы от бинарников
#   и выносит их в debuginfo, а исходники, на которые эти символы ссылаются, —
#   в debugsource. Благодаря этому retroshare остаётся компактным, а gdb, ABRT и
#   coredumpctl всё равно умеют показывать стек с именами функций и строками.
#   Для запуска нужен только retroshare. Пакеты debuginfo/debugsource должны
#   совпадать с ним по версии и сборке (связь через build-id).
#   Они не нужны, если отладка не планируется: RS_NODEBUG=1 их не создаёт.
#   Четвёртый артефакт — retroshare-*.src.rpm в SRPMS/.
#
# ИСХОДНИКИ НЕ ПАТЧАТСЯ
#   Единственная правка в %prep относится к сборочной логике, а не к коду:
#   заглушка RS_LIB_VERSION_HASH «[version not available]» (в tarball нет .git)
#   содержит пробелы и непригодна как значение -D...; она заменяется хешем
#   коммита.
#   Код RetroShare уже работает с API OpenSSL 1.1+/3, патчи не требуются.
#
# ЯРЛЫК И ИКОНКИ
#   Ярлык (retroshare.desktop, Source3) ставит сам spec, а не правило upstream
#   `make install`: upstream-файл содержит устаревший ключ Encoding, имя иконки
#   с расширением (retroshare.xpm), абсолютный путь в Exec и список Categories
#   без завершающей «;», то есть не проходит desktop-file-validate. Свой файл
#   ставится через desktop-file-install, который его же и проверяет (при ошибке
#   сборка прерывается) и заменяет upstream-версию. Растровые иконки hicolor
#   (24/48/64/128 px) ставит upstream, масштабируемую retroshare.svg — spec.
#   Окно RetroShare получает app_id «retroshare», совпадающий с именем
#   retroshare.desktop, поэтому GNOME связывает окно с ярлыком и иконкой без
#   StartupWMClass.
#
# СОВМЕСТИМОСТЬ С SHA-1 (старые сертификаты и подписи RetroShare)
#   Решается окружением процесса, а не патчами. Обёртка /usr/bin/retroshare
#   задаёт:
#     OPENSSL_ENABLE_SHA1_SIGNATURES=1   — переменная даунстрим-патча OpenSSL
#         в Fedora/RHEL (в upstream OpenSSL её нет), разрешает SHA-1 подписи;
#     OPENSSL_CONF=/etc/retroshare/openssl-rs.cnf   — SECLEVEL=0: в OpenSSL 3
#         SHA-1 отвергается уже на SECLEVEL=1.
#   Уже заданные пользователем значения обёртка не перезаписывает.
#   Ограничения: на время работы RetroShare системная crypto-policy для его
#   процесса заменяется конфигом из пакета (остальные программы не затронуты),
#   а переменные окружения наследуют и процессы, запущенные из RetroShare.
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ
#   RS_REF=master        ветка, тег (например, v0.6.7.3) или хеш коммита
#   RS_VERSION=X.Y.Z     принудительно задать Version в spec
#   RS_WORKDIR=DIR       рабочая директория (по умолчанию — каталог скрипта)
#   RS_JOBS=N            число потоков сборки (по умолчанию — по объёму ОЗУ)
#   RS_NODEBUG=1         не создавать debuginfo/debugsource
#   SKIP_DEPS=1          не вызывать dnf (зависимости уже установлены)
#   FORCE_RECLONE=1      удалить и заново склонировать исходники
#   RPM_CHANGELOG_WHO    «Имя <email>» для %changelog (по умолчанию — из git config)
# =============================================================================
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
          echo -e "${CYAN}  $*${NC}"
          echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }
trap 'error "Сбой на строке $LINENO: $BASH_COMMAND"' ERR

# Экранирование значения для правой части sed-замены s|...|...|
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Тип артефакта по имени файла: main | debuginfo | debugsource | srpm
rpm_kind() {
    case "$1" in
        *-debuginfo-*)   echo debuginfo ;;
        *-debugsource-*) echo debugsource ;;
        *.src.rpm)       echo srpm ;;
        *)               echo main ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
# Абсолютный путь обязателен: он попадает в %_topdir, а rpmbuild относительных не терпит.
RS_WORKDIR="$(realpath -m "${RS_WORKDIR:-$SCRIPT_DIR}")"
RS_REF="${RS_REF:-master}"
TOPDIR="$RS_WORKDIR/_rpmbuild"
LOGDIR="$RS_WORKDIR/_logs"
mkdir -p "$RS_WORKDIR" "$LOGDIR"

# Подмодули, которые не нужны для десктопной сборки
SUBMODULE_EXCLUDE='^(build_scripts/OBS|openpgpsdk|supportlibs/jni\.hpp)$'

# =============================================================================
# 1. ИНСТРУМЕНТЫ
# =============================================================================
step "1/6  Инструменты"
if [ "${SKIP_DEPS:-0}" = "1" ]; then
    info "SKIP_DEPS=1 — пропущено"
else
    # Только то, что нужно самому скрипту; BuildRequires ставит dnf builddep (шаг 4).
    sudo dnf install -y rpm-build git tar gzip 'dnf-command(builddep)'
fi

# =============================================================================
# 2. ИСХОДНИКИ
# =============================================================================
step "2/6  Исходники ($RS_REF)"
cd "$RS_WORKDIR"

if [ "${FORCE_RECLONE:-0}" = "1" ] && [ -d retroshare ]; then
    warn "FORCE_RECLONE=1: удаляю $RS_WORKDIR/retroshare"
    rm -rf retroshare
fi
if [ ! -d retroshare/.git ]; then
    info "Клонирование RetroShare..."
    git clone https://github.com/RetroShare/RetroShare.git retroshare
fi
cd retroshare

git fetch --tags --force --prune origin
if git rev-parse -q --verify "refs/tags/${RS_REF}^{commit}" >/dev/null; then
    TARGET="refs/tags/${RS_REF}"
elif git rev-parse -q --verify "refs/remotes/origin/${RS_REF}^{commit}" >/dev/null; then
    TARGET="refs/remotes/origin/${RS_REF}"
elif git rev-parse -q --verify "${RS_REF}^{commit}" >/dev/null; then
    TARGET="$RS_REF"                                  # хеш коммита
else
    error "RS_REF=$RS_REF: не найден ни тег, ни ветка, ни коммит"
    exit 1
fi
# Рабочая копия служит только источником для tarball: любые локальные
# изменения отбрасываются, чтобы Source0 строго соответствовал коммиту.
git checkout -q --force --detach "$TARGET"
git clean -ffdxq

mapfile -t SUBS < <(git config -f .gitmodules --get-regexp '\.path$' \
                    | awk '{print $2}' | grep -vE "$SUBMODULE_EXCLUDE")
[ "${#SUBS[@]}" -gt 0 ] || { error "Список подмодулей пуст"; exit 1; }
git submodule sync --recursive -q
git submodule update --init --recursive --force -- "${SUBS[@]}"
git submodule foreach --recursive -q 'git reset -q --hard; git clean -ffdxq'

COMMIT="$(git rev-parse --short=8 HEAD)"
COMMIT_TS="$(git log -1 --format=%ct)"
info "Коммит: $COMMIT"

# ── Версия ───────────────────────────────────────────────────────────────────
# Тег:    Version = тег, Release = 1.
# Снимок: Version = последний тег, Release = 1.<дата коммита>git<хеш>
#         (post-release snapshot по Fedora Packaging Guidelines: снимок новее тега).
if TAG="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null)"; then
    VERSION="${TAG#v}"
    RELEASE="1"
    RS_EXTRA=""
else
    BASE="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)"
    VERSION="${BASE#v}"
    RELEASE="1.$(git log -1 --format=%cd --date=format:%Y%m%d)git${COMMIT}"
    RS_EXTRA="git${COMMIT}"
fi
if [ -n "${RS_VERSION:-}" ]; then
    VERSION="$RS_VERSION"
fi
VERSION="${VERSION//-/.}"                      # '-' запрещён в RPM Version
VERSION="$(tr -dc '[:alnum:]._+' <<<"$VERSION")"
info "Версия пакета: ${VERSION}-${RELEASE}"

# Версию передаём в qmake явно: в tarball нет .git, а retroshare.pri иначе
# пытается вызвать `git describe`. Поддерживаются X.Y.Z и X.Y.Z.N
# (четвёртый компонент уходит в RS_EXTRA_VERSION).
QMAKE_VERSION_ARGS=""
if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
    QMAKE_VERSION_ARGS="RS_MAJOR_VERSION=${BASH_REMATCH[1]} RS_MINOR_VERSION=${BASH_REMATCH[2]} RS_MINI_VERSION=${BASH_REMATCH[3]} RS_EXTRA_VERSION=${BASH_REMATCH[4]}${RS_EXTRA}"
else
    warn "Версия '$VERSION' не в формате X.Y.Z[.N]: версия в qmake не передаётся"
fi

# ── Source0 ──────────────────────────────────────────────────────────────────
cd "$RS_WORKDIR"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
SOURCE0="retroshare-${VERSION}-${COMMIT}.tar.gz"
info "Упаковка $SOURCE0 ..."
tar --exclude='.git' --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${COMMIT_TS}" \
    --transform "s,^retroshare,retroshare-${VERSION}," \
    -cf - retroshare | gzip -n > "$TOPDIR/SOURCES/$SOURCE0"

# =============================================================================
# 3. ВСПОМОГАТЕЛЬНЫЕ ФАЙЛЫ ПАКЕТА (Source1–Source3)
# =============================================================================
step "3/6  Обёртка запуска, конфиг OpenSSL и ярлык"

# Метки __LIBEXECDIR__ и __SYSCONFDIR__ подставляются в %install из макросов
# %{_libexecdir} и %{_sysconfdir}.
cat > "$TOPDIR/SOURCES/retroshare-wrapper.sh" << 'WRAPPER_EOF'
#!/bin/sh
# Запуск RetroShare с окружением совместимости OpenSSL 3.
# /usr/bin/retroshare и /usr/bin/retroshare-service → этот скрипт →
# libexec/retroshare/<то же имя>.
# Значения, уже заданные пользователем, не перезаписываются.

: "${OPENSSL_ENABLE_SHA1_SIGNATURES:=1}"
export OPENSSL_ENABLE_SHA1_SIGNATURES

if [ -z "${OPENSSL_CONF:-}" ] && [ -r __SYSCONFDIR__/retroshare/openssl-rs.cnf ]; then
    OPENSSL_CONF=__SYSCONFDIR__/retroshare/openssl-rs.cnf
    export OPENSSL_CONF
fi

exec "__LIBEXECDIR__/retroshare/${0##*/}" "$@"
WRAPPER_EOF

cat > "$TOPDIR/SOURCES/openssl-rs.cnf" << 'OPENSSL_EOF'
# OpenSSL-конфиг только для процесса RetroShare (см. /usr/bin/retroshare).
#
# Сертификаты и подписи RetroShare используют SHA-1. В OpenSSL 3.x SHA-1
# отвергается уже на SECLEVEL=1 (и на SECLEVEL=2 по умолчанию в Fedora),
# поэтому для RetroShare уровень снижен до 0. Системная политика
# crypto-policies для остальных программ не затрагивается; для самого
# RetroShare этот файл заменяет системный openssl.cnf целиком.
# Подпись SHA-1 дополнительно разрешается переменной
# OPENSSL_ENABLE_SHA1_SIGNATURES=1 (задаётся обёрткой).
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect
ssl_conf  = ssl_sect

[provider_sect]
default = default_sect

[default_sect]
activate = 1

[ssl_sect]
system_default = system_default_sect

[system_default_sect]
CipherString = DEFAULT:@SECLEVEL=0
MinProtocol  = TLSv1.2
OPENSSL_EOF

cat > "$TOPDIR/SOURCES/retroshare.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=RetroShare
GenericName=Friend-to-friend communication
Comment=Securely communicate with your friends
Exec=retroshare %U
Icon=retroshare
Terminal=false
Categories=Network;Email;InstantMessaging;Chat;Feed;FileTransfer;P2P;
Keywords=retroshare;chat;forum;file sharing;friend-to-friend;p2p;
MimeType=x-scheme-handler/retroshare;
DESKTOP_EOF
info "Source1–Source3 созданы ✓"

# =============================================================================
# 4. SPEC-ФАЙЛ И BUILDREQUIRES
# =============================================================================
step "4/6  retroshare.spec"
SPEC_FILE="$TOPDIR/SPECS/retroshare.spec"
# Дата в %changelog — дата коммита, чтобы spec не менялся от запуска к запуску.
CHANGELOG_DATE="$(LC_ALL=C date -u -d "@${COMMIT_TS}" +'%a %b %d %Y')"
if [ -n "${RPM_CHANGELOG_WHO:-}" ]; then
    CHANGELOG_WHO="$RPM_CHANGELOG_WHO"
else
    CHANGELOG_WHO="$(git config user.name || echo Builder) <$(git config user.email || echo builder@localhost)>"
fi

cat > "$SPEC_FILE" << 'SPEC_EOF'
%global commit @COMMIT@

Name:           retroshare
Version:        @VERSION@
Release:        @RELEASE@%{?dist}
Summary:        Encrypted friend-to-friend communication platform
# Выражение составлено вручную по upstream COPYING (AGPL-3.0-only — основной
# код; LGPL-3.0-or-later — libretroshare и libbitdht; GPL-3.0-or-later — GUI;
# BSD-3-Clause — TorControl; MIT — PictureFlow) и по лицензиям встроенных
# библиотек (librnp: BSD-2-Clause и Apache-2.0; libsam3, udp-discovery-cpp,
# rapidjson: MIT; restbed: AGPL). Сканером не проверялось: перед публикацией
# пакета сверьте его с исходниками (например, licensecheck -r).
License:        AGPL-3.0-only AND LGPL-3.0-or-later AND GPL-3.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Apache-2.0
URL:            https://retroshare.cc
# Source0 собирается скриптом из git-checkout вместе с submodules
# (архивы GitHub их не содержат), поэтому скачать его по URL нельзя.
Source0:        @SOURCE0@
Source1:        retroshare-wrapper.sh
Source2:        openssl-rs.cnf
Source3:        retroshare.desktop

BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
BuildRequires:  git-core
BuildRequires:  pkgconf-pkg-config
BuildRequires:  python3
BuildRequires:  doxygen
BuildRequires:  desktop-file-utils
BuildRequires:  qt6-rpm-macros
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtmultimedia-devel
BuildRequires:  qt6-qt5compat-devel
BuildRequires:  qt6-qtsvg-devel
BuildRequires:  qt6-qttools-devel
BuildRequires:  qt6-linguist
BuildRequires:  openssl-devel
BuildRequires:  bzip2-devel
BuildRequires:  zlib-devel
BuildRequires:  sqlite-devel
BuildRequires:  sqlcipher-devel
BuildRequires:  json-c-devel
BuildRequires:  libupnp-devel
BuildRequires:  miniupnpc-devel
BuildRequires:  libcurl-devel
BuildRequires:  libxml2-devel
BuildRequires:  libxslt-devel
BuildRequires:  speexdsp-devel
BuildRequires:  libsecret-devel
BuildRequires:  libXScrnSaver-devel
BuildRequires:  rapidjson-devel
BuildRequires:  asio-devel
# FFmpeg: через pkg-config — подойдёт и ffmpeg-free (Fedora), и RPM Fusion
BuildRequires:  pkgconfig(libavcodec)
BuildRequires:  pkgconfig(libavformat)
BuildRequires:  pkgconfig(libavutil)
BuildRequires:  pkgconfig(libswscale)

# Подключаемые плагины Qt (не видны автогенератору зависимостей)
Requires:       qt6-qtsvg
Requires:       hicolor-icon-theme
Recommends:     qt6-qtwayland

# Библиотеки, которые сборка берёт из supportlibs и линкует статически
Provides:       bundled(libsam3)
Provides:       bundled(librnp)
Provides:       bundled(restbed)
Provides:       bundled(udp-discovery-cpp)
# Плагины всегда берут заголовки rapidjson из supportlibs, а libretroshare —
# системные (rapidjson-devel), если их находит pkg-config.
Provides:       bundled(rapidjson) = 1.1.0

%description
RetroShare is a decentralized, encrypted friend-to-friend platform: chat,
forums, channels, file sharing and voice/video, with no central server.

This package ships a launcher that enables SHA-1 signature compatibility
for the RetroShare process only (OPENSSL_ENABLE_SHA1_SIGNATURES and
/etc/retroshare/openssl-rs.cnf), leaving the system crypto policy intact.

%prep
%autosetup -n %{name}-%{version}

# В tarball нет .git, поэтому libretroshare.pro подставляет в
# RS_LIB_VERSION_HASH заглушку "[version not available]". Пробелы в ней
# недопустимы в значении -DRS_LIB_VERSION_HASH=...: заглушка заменяется
# хешем коммита, после чего проверяется, что ни одной не осталось.
grep -rlF '[version not available]' --include='*.pro' --include='*.pri' . \
    | xargs -r sed -i 's|\[version not available\]|%{commit}|g'
if grep -rF '[version not available]' --include='*.pro' --include='*.pri' . ; then
    echo "ERROR: заглушка версии с пробелами осталась в .pro/.pri" >&2
    exit 1
fi

# Правило librnp_header в libretroshare.pro вызывает
# `git submodule update --init src/libsexpp`, а в tarball нет .git.
# Подмодули уже развёрнуты в Source0, поэтому подкоманда `submodule`
# через shim в PATH — no-op; остальные вызовы git выполняются как обычно.
mkdir -p %{_builddir}/git-shim
cat > %{_builddir}/git-shim/git << 'GITSHIM_EOF'
#!/bin/sh
if [ "$1" = "submodule" ]; then
    exit 0
fi
exec /usr/bin/git "$@"
GITSHIM_EOF
chmod 0755 %{_builddir}/git-shim/git

%build
export PATH=%{_builddir}/git-shim:$PATH

# libsam3 (supportlibs) собирается своим Makefile с `CFLAGS := ...`: такое
# присваивание перекрывает CFLAGS из окружения, а CC и цели жёстко заданы в
# libretroshare.pro. Статической libsam3.a нужен -fPIC (линковка в
# PIE-бинарники Fedora). Единственная переменная, которую этот Makefile берёт
# из окружения и подставляет в строку компиляции, — LDFLAGS; -fPIC туда
# безвреден и для остальных линковок. Значение по умолчанию (build_ldflags)
# сохраняется явно: макрос qmake_qt6 подставляет его только если LDFLAGS не задана.
export LDFLAGS="${LDFLAGS:-%{build_ldflags}} -fPIC"

# Плагины (FeedReader и др.) берут встроенный supportlibs/rapidjson 1.1.0
# через обычный -I, а не -isystem, и GCC 16 в нём считает ошибкой
# -Wtemplate-body. Отключена именно эта диагностика; исходники не меняются.
%{qmake_qt6} RetroShare.pro \
    CONFIG+=release \
    CONFIG+=rs_jsonapi \
    CONFIG+=rs_webui \
    CONFIG+=rs_autologin \
    CONFIG+=retroshare_plugins \
    PREFIX=%{_prefix} \
    RS_BIN_DIR=%{_libexecdir}/retroshare \
    RS_LIB_DIR=%{_libdir} \
    RS_PLUGIN_DIR=%{_libdir}/retroshare/extensions6 \
    RS_DATA_DIR=%{_datadir}/retroshare \
    QMAKE_CXXFLAGS+=-Wno-template-body \
    @QMAKE_VERSION_ARGS@

%make_build

%install
export PATH=%{_builddir}/git-shim:$PATH
make install INSTALL_ROOT=%{buildroot}

# Раскладка: настоящие бинарники лежат в libexec (RS_BIN_DIR), а в /usr/bin
# стоит обёртка, задающая окружение OpenSSL. Если upstream положил бинарник
# не туда, обёртка перезаписала бы его или указывала бы в пустоту, поэтому
# раскладка проверяется явно.
test -x %{buildroot}%{_libexecdir}/retroshare/retroshare || {
    echo "ERROR: нет %{_libexecdir}/retroshare/retroshare — RS_BIN_DIR не сработал" >&2
    exit 1
}
test ! -e %{buildroot}%{_bindir}/retroshare || {
    echo "ERROR: upstream уже установил %{_bindir}/retroshare, обёртка его затёрла бы" >&2
    exit 1
}

install -Dpm0755 %{SOURCE1} %{buildroot}%{_bindir}/retroshare
sed -i -e 's|__LIBEXECDIR__|%{_libexecdir}|g' \
       -e 's|__SYSCONFDIR__|%{_sysconfdir}|g' %{buildroot}%{_bindir}/retroshare
if grep -q '__[A-Z]\+__' %{buildroot}%{_bindir}/retroshare; then
    echo "ERROR: в обёртке остались неподставленные метки" >&2
    exit 1
fi
# retroshare-service — та же обёртка под другим именем (обёртка запускает
# одноимённый файл из libexec), создаётся только если он собран.
if [ -x %{buildroot}%{_libexecdir}/retroshare/retroshare-service ]; then
    ln -s retroshare %{buildroot}%{_bindir}/retroshare-service
fi

install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/retroshare/openssl-rs.cnf

# Ярлык: собственный файл (Source3). desktop-file-install проверяет его и
# при ошибке прерывает сборку; одноимённый upstream-файл заменяется.
desktop-file-install --dir=%{buildroot}%{_datadir}/applications %{SOURCE3}

# Иконки hicolor: растровые размеры ставит upstream (проверяем), svg — нет.
for size in 24x24 48x48 64x64 128x128; do
    test -f %{buildroot}%{_datadir}/icons/hicolor/$size/apps/retroshare.png || {
        echo "ERROR: upstream не установил иконку $size" >&2
        exit 1
    }
done
install -Dpm0644 data/retroshare.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/retroshare.svg

# Список файлов: всё, что поставил upstream `make install`, плюс файлы
# пакета. Явный перечень не используется: раскладка зависит от флагов qmake
# и версии upstream. %%dir ставится только на каталоги, принадлежащие
# этому пакету (общие вроде /usr/share/applications не затрагиваются);
# файлы в /etc помечаются как конфигурация.
{
  for d in %{_sysconfdir}/retroshare %{_libexecdir}/retroshare \
           %{_datadir}/retroshare %{_libdir}/retroshare; do
      if [ -d "%{buildroot}$d" ]; then
          find "%{buildroot}$d" -type d | sed 's|^%{buildroot}|%%dir |'
      fi
  done
  find %{buildroot} \( -type f -o -type l \) \
      | sed -e 's|^%{buildroot}||' \
            -e 's|^%{_sysconfdir}/|%%config(noreplace) &|' \
      | sort
} > %{_builddir}/%{name}-files.lst

%files -f %{_builddir}/%{name}-files.lst
%license COPYING LICENSES
%doc README.md

%changelog
* @CHANGELOG_DATE@ @CHANGELOG_WHO@ - @VERSION@-@RELEASE@
- Build of RetroShare @COMMIT@ with unpatched upstream sources
- Launcher sets OPENSSL_ENABLE_SHA1_SIGNATURES=1 and OPENSSL_CONF for RetroShare only
- Install own desktop entry and scalable icon (upstream desktop file is invalid)
SPEC_EOF

declare -A SUBST=(
    [VERSION]="$VERSION"
    [RELEASE]="$RELEASE"
    [SOURCE0]="$SOURCE0"
    [COMMIT]="$COMMIT"
    [QMAKE_VERSION_ARGS]="$QMAKE_VERSION_ARGS"
    [CHANGELOG_DATE]="$CHANGELOG_DATE"
    [CHANGELOG_WHO]="$CHANGELOG_WHO"
)
for key in "${!SUBST[@]}"; do
    sed -i "s|@${key}@|$(sed_escape "${SUBST[$key]}")|g" "$SPEC_FILE"
done
if LEFT="$(grep -nE '@[A-Z_0-9]+@' "$SPEC_FILE")"; then
    error "В spec остались неподставленные метки:"; echo "$LEFT" >&2
    exit 1
fi
info "Spec: $SPEC_FILE ✓"

if [ "${SKIP_DEPS:-0}" != "1" ]; then
    info "Установка BuildRequires (dnf builddep)..."
    sudo dnf builddep -y "$SPEC_FILE"
fi

# =============================================================================
# 5. СБОРКА
# =============================================================================
step "5/6  rpmbuild -ba"
# Число потоков: LTO (-flto=auto) + -O2 требуют ~2 ГБ ОЗУ на каждый cc1plus,
# при нехватке памяти OOM-killer убивает компилятор.
if [ -z "${RS_JOBS:-}" ]; then
    MEM_GB=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
    RS_JOBS=$(( MEM_GB / 2 )); [ "$RS_JOBS" -ge 1 ] || RS_JOBS=1
    [ "$RS_JOBS" -le "$(nproc)" ] || RS_JOBS="$(nproc)"
fi
[[ "$RS_JOBS" =~ ^[1-9][0-9]*$ ]] || { error "RS_JOBS='$RS_JOBS': нужно целое число > 0"; exit 1; }
info "Потоков сборки: $RS_JOBS (RS_JOBS=N чтобы изменить)"

RPMBUILD_ARGS=(--define "_topdir $TOPDIR" --define "_smp_mflags -j${RS_JOBS}")
if [ "${RS_NODEBUG:-0}" = "1" ]; then
    info "RS_NODEBUG=1 — debuginfo/debugsource создаваться не будут"
    RPMBUILD_ARGS+=(--define 'debug_package %{nil}')
fi

if ! rpmbuild -ba "${RPMBUILD_ARGS[@]}" "$SPEC_FILE" 2>&1 | tee "$LOGDIR/rpmbuild.log"; then
    error "rpmbuild завершился с ошибкой, полный лог: $LOGDIR/rpmbuild.log"
    # При параллельной сборке причина сбоя обычно в середине лога, а не в конце.
    warn "Вероятные причины (первые совпадения):"
    grep -nE 'error:|Error [0-9]+|\*\*\*|undefined reference|Killed signal|fatal error' \
        "$LOGDIR/rpmbuild.log" | grep -vE 'Werror=format-security|warning:' | head -n 30 || true
    exit 1
fi

# =============================================================================
# 6. ПРОВЕРКА И РЕЗУЛЬТАТ
# =============================================================================
step "6/6  Результат"
mapfile -t BUILT < <(find "$TOPDIR/RPMS" "$TOPDIR/SRPMS" -name "retroshare*-${VERSION}-${RELEASE}.*.rpm" | sort)
[ "${#BUILT[@]}" -gt 0 ] || { error "RPM не найдены в $TOPDIR"; exit 1; }

MAIN_RPM=""
for f in "${BUILT[@]}"; do
    if [ "$(rpm_kind "$f")" = "main" ]; then MAIN_RPM="$f"; break; fi
done
[ -n "$MAIN_RPM" ] || { error "Основной пакет не найден среди собранных"; exit 1; }

info "Состав пакета:";  rpm -qlp "$MAIN_RPM" | sed 's/^/    /'
info "Зависимости:";    rpm -qRp "$MAIN_RPM" | sed 's/^/    /'

# Обязательное содержимое: обёртка, настоящий бинарник, конфиг, ярлык и иконка
# (без ярлыка и иконки GNOME не покажет приложение в поиске).
# Список читаем один раз: «rpm | grep -q» при pipefail даёт ложную ошибку (SIGPIPE).
PKG_FILES="$(rpm -qlp "$MAIN_RPM")"
for need in '^/usr/bin/retroshare$' \
            '^/usr/libexec/retroshare/retroshare$' \
            '^/etc/retroshare/openssl-rs\.cnf$' \
            '^/usr/share/applications/retroshare\.desktop$' \
            '^/usr/share/icons/hicolor/[^/]+/apps/retroshare\.(png|svg)$'; do
    grep -qE "$need" <<<"$PKG_FILES" \
        || { error "В пакете нет файла по шаблону: $need"; exit 1; }
done

# Upstream не устанавливает заголовки и статические библиотеки. Появление их в
# списке означает, что раскладка изменилась и пакет нужно разделить на -devel/-static.
if DEVFILES="$(grep -E '^/usr/include/|\.a$' <<<"$PKG_FILES")"; then
    warn "В пакете retroshare есть файлы разработки (кандидаты в -devel/-static):"
    echo "$DEVFILES" | head -n 10 | sed 's/^/    /'
fi
if command -v rpmlint >/dev/null 2>&1; then
    info "rpmlint:"; rpmlint "$MAIN_RPM" || true
fi

echo -e "\n${GREEN}Готово:${NC}"
for f in "${BUILT[@]}"; do
    case "$(rpm_kind "$f")" in
        debuginfo)   role="отладочные символы (для gdb/ABRT, не обязателен)" ;;
        debugsource) role="исходники для отладки (не обязателен)" ;;
        srpm)        role="исходный пакет (SRPM)" ;;
        main)        role="основной пакет — его и устанавливать" ;;
    esac
    printf '  %s\n      %s\n' "$f" "$role"
done
echo -e "\nУстановка:  sudo dnf install $MAIN_RPM"
echo "Запуск:     retroshare"
