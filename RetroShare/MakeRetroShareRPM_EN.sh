#!/bin/bash
# =============================================================================
# MakeRetroShareRPM.sh — build the RetroShare RPM for Fedora (Qt6, OpenSSL 3.x)
#
# PROCESS (the canonical RPM cycle)
#   1. Sources    a clean git checkout + submodules → Source0 (tar.gz).
#                 The archive is built by the script itself: GitHub archives
#                 have no submodules, and RetroShare does not build without
#                 them. The archive is deterministic (file order, owner,
#                 mtime, gzip -n).
#   2. Spec       generated from a template; %prep / %build / %install / %files.
#                 BuildRequires are installed by `dnf builddep` from the spec itself.
#   3. rpmbuild -ba → binary packages + SRPM.
#
# WHICH PACKAGES ARE PRODUCED
#   The spec describes a single package — retroshare. Two more
#   (retroshare-debuginfo and retroshare-debugsource) are created by rpmbuild
#   itself: after %install, the %debug_package macro from redhat-rpm-config
#   separates debug symbols from the binaries and moves them into debuginfo,
#   while the sources those symbols refer to go into debugsource. Thanks to
#   this, retroshare stays compact, while gdb, ABRT and coredumpctl can still
#   show a stack trace with function names and line numbers.
#   Only retroshare is needed to run the program. The debuginfo/debugsource
#   packages must match it in version and build (linked via build-id).
#   They are not needed if you do not plan to debug: RS_NODEBUG=1 does not
#   create them.
#   The fourth artifact is retroshare-*.src.rpm in SRPMS/.
#
# SOURCES ARE NOT PATCHED
#   The only change in %prep concerns build logic, not code:
#   the RS_LIB_VERSION_HASH placeholder "[version not available]" (the tarball
#   has no .git) contains spaces and is unusable as a -D... value; it is
#   replaced with the commit hash.
#   RetroShare code already works with the OpenSSL 1.1+/3 API, no patches are needed.
#
# DESKTOP ENTRY AND ICONS
#   The desktop entry (retroshare.desktop, Source3) is installed by the spec
#   itself, not by the upstream `make install` rule: the upstream file contains
#   the obsolete Encoding key, an icon name with an extension (retroshare.xpm),
#   an absolute path in Exec, and a Categories list without a trailing ";",
#   i.e. it does not pass desktop-file-validate. Our own file is installed via
#   desktop-file-install, which also validates it (the build aborts on error)
#   and replaces the upstream version. The raster hicolor icons (24/48/64/128
#   px) are installed by upstream, the scalable retroshare.svg by the spec.
#   The RetroShare window gets the app_id "retroshare", matching the name of
#   retroshare.desktop, so GNOME associates the window with the desktop entry
#   and icon without StartupWMClass.
#
# SHA-1 COMPATIBILITY (old RetroShare certificates and signatures)
#   Solved through the process environment, not through patches. The
#   /usr/bin/retroshare wrapper sets:
#     OPENSSL_ENABLE_SHA1_SIGNATURES=1   — a variable from the downstream
#         OpenSSL patch in Fedora/RHEL (absent from upstream OpenSSL), it
#         allows SHA-1 signatures;
#     OPENSSL_CONF=/etc/retroshare/openssl-rs.cnf   — SECLEVEL=0: in OpenSSL 3
#         SHA-1 is already rejected at SECLEVEL=1.
#   Values already set by the user are not overwritten by the wrapper.
#   Limitations: while RetroShare is running, the system crypto-policy for its
#   process is replaced by the config from the package (other programs are not
#   affected), and the environment variables are also inherited by processes
#   launched from RetroShare.
#
# ENVIRONMENT VARIABLES
#   RS_REF=master        branch, tag (e.g. v0.6.7.3) or commit hash
#   RS_VERSION=X.Y.Z     force the Version in the spec
#   RS_WORKDIR=DIR       working directory (default — the script's directory)
#   RS_JOBS=N            number of build threads (default — based on RAM size)
#   RS_NODEBUG=1         do not create debuginfo/debugsource
#   SKIP_DEPS=1          do not call dnf (dependencies are already installed)
#   FORCE_RECLONE=1      delete and re-clone the sources
#   RPM_CHANGELOG_WHO    "Name <email>" for %changelog (default — from git config)
# =============================================================================
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
          echo -e "${CYAN}  $*${NC}"
          echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }
trap 'error "Failure at line $LINENO: $BASH_COMMAND"' ERR

# Escape a value for the right-hand side of a sed substitution s|...|...|
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Artifact type by file name: main | debuginfo | debugsource | srpm
rpm_kind() {
    case "$1" in
        *-debuginfo-*)   echo debuginfo ;;
        *-debugsource-*) echo debugsource ;;
        *.src.rpm)       echo srpm ;;
        *)               echo main ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
# An absolute path is mandatory: it ends up in %_topdir, and rpmbuild does not tolerate relative ones.
RS_WORKDIR="$(realpath -m "${RS_WORKDIR:-$SCRIPT_DIR}")"
RS_REF="${RS_REF:-master}"
TOPDIR="$RS_WORKDIR/_rpmbuild"
LOGDIR="$RS_WORKDIR/_logs"
mkdir -p "$RS_WORKDIR" "$LOGDIR"

# Submodules that are not needed for the desktop build
SUBMODULE_EXCLUDE='^(build_scripts/OBS|openpgpsdk|supportlibs/jni\.hpp)$'

# =============================================================================
# 1. TOOLS
# =============================================================================
step "1/6  Tools"
if [ "${SKIP_DEPS:-0}" = "1" ]; then
    info "SKIP_DEPS=1 — skipped"
else
    # Only what the script itself needs; BuildRequires are installed by dnf builddep (step 4).
    sudo dnf install -y rpm-build git tar gzip 'dnf-command(builddep)'
fi

# =============================================================================
# 2. SOURCES
# =============================================================================
step "2/6  Sources ($RS_REF)"
cd "$RS_WORKDIR"

if [ "${FORCE_RECLONE:-0}" = "1" ] && [ -d retroshare ]; then
    warn "FORCE_RECLONE=1: removing $RS_WORKDIR/retroshare"
    rm -rf retroshare
fi
if [ ! -d retroshare/.git ]; then
    info "Cloning RetroShare..."
    git clone https://github.com/RetroShare/RetroShare.git retroshare
fi
cd retroshare

git fetch --tags --force --prune origin
if git rev-parse -q --verify "refs/tags/${RS_REF}^{commit}" >/dev/null; then
    TARGET="refs/tags/${RS_REF}"
elif git rev-parse -q --verify "refs/remotes/origin/${RS_REF}^{commit}" >/dev/null; then
    TARGET="refs/remotes/origin/${RS_REF}"
elif git rev-parse -q --verify "${RS_REF}^{commit}" >/dev/null; then
    TARGET="$RS_REF"                                  # commit hash
else
    error "RS_REF=$RS_REF: neither a tag, nor a branch, nor a commit was found"
    exit 1
fi
# The working copy serves only as the source for the tarball: any local
# changes are discarded so that Source0 strictly matches the commit.
git checkout -q --force --detach "$TARGET"
git clean -ffdxq

mapfile -t SUBS < <(git config -f .gitmodules --get-regexp '\.path$' \
                    | awk '{print $2}' | grep -vE "$SUBMODULE_EXCLUDE")
[ "${#SUBS[@]}" -gt 0 ] || { error "Submodule list is empty"; exit 1; }
git submodule sync --recursive -q
git submodule update --init --recursive --force -- "${SUBS[@]}"
git submodule foreach --recursive -q 'git reset -q --hard; git clean -ffdxq'

COMMIT="$(git rev-parse --short=8 HEAD)"
COMMIT_TS="$(git log -1 --format=%ct)"
info "Commit: $COMMIT"

# ── Version ──────────────────────────────────────────────────────────────────
# Tag:      Version = tag, Release = 1.
# Snapshot: Version = latest tag, Release = 1.<commit date>git<hash>
#           (post-release snapshot per the Fedora Packaging Guidelines: the snapshot is newer than the tag).
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
VERSION="${VERSION//-/.}"                      # '-' is forbidden in an RPM Version
VERSION="$(tr -dc '[:alnum:]._+' <<<"$VERSION")"
info "Package version: ${VERSION}-${RELEASE}"

# The version is passed to qmake explicitly: the tarball has no .git, and
# retroshare.pri would otherwise try to call `git describe`. X.Y.Z and X.Y.Z.N
# are supported (the fourth component goes into RS_EXTRA_VERSION).
QMAKE_VERSION_ARGS=""
if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
    QMAKE_VERSION_ARGS="RS_MAJOR_VERSION=${BASH_REMATCH[1]} RS_MINOR_VERSION=${BASH_REMATCH[2]} RS_MINI_VERSION=${BASH_REMATCH[3]} RS_EXTRA_VERSION=${BASH_REMATCH[4]}${RS_EXTRA}"
else
    warn "Version '$VERSION' is not in the X.Y.Z[.N] format: version is not passed to qmake"
fi

# ── Source0 ──────────────────────────────────────────────────────────────────
cd "$RS_WORKDIR"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
SOURCE0="retroshare-${VERSION}-${COMMIT}.tar.gz"
info "Packing $SOURCE0 ..."
tar --exclude='.git' --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${COMMIT_TS}" \
    --transform "s,^retroshare,retroshare-${VERSION}," \
    -cf - retroshare | gzip -n > "$TOPDIR/SOURCES/$SOURCE0"

# =============================================================================
# 3. AUXILIARY PACKAGE FILES (Source1–Source3)
# =============================================================================
step "3/6  Launch wrapper, OpenSSL config and desktop entry"

# The __LIBEXECDIR__ and __SYSCONFDIR__ markers are substituted in %install
# from the %{_libexecdir} and %{_sysconfdir} macros.
cat > "$TOPDIR/SOURCES/retroshare-wrapper.sh" << 'WRAPPER_EOF'
#!/bin/sh
# Launch RetroShare with the OpenSSL 3 compatibility environment.
# /usr/bin/retroshare and /usr/bin/retroshare-service → this script →
# libexec/retroshare/<same name>.
# Values already set by the user are not overwritten.

: "${OPENSSL_ENABLE_SHA1_SIGNATURES:=1}"
export OPENSSL_ENABLE_SHA1_SIGNATURES

if [ -z "${OPENSSL_CONF:-}" ] && [ -r __SYSCONFDIR__/retroshare/openssl-rs.cnf ]; then
    OPENSSL_CONF=__SYSCONFDIR__/retroshare/openssl-rs.cnf
    export OPENSSL_CONF
fi

exec "__LIBEXECDIR__/retroshare/${0##*/}" "$@"
WRAPPER_EOF

cat > "$TOPDIR/SOURCES/openssl-rs.cnf" << 'OPENSSL_EOF'
# OpenSSL config for the RetroShare process only (see /usr/bin/retroshare).
#
# RetroShare certificates and signatures use SHA-1. In OpenSSL 3.x SHA-1
# is already rejected at SECLEVEL=1 (and at SECLEVEL=2, the Fedora default),
# so for RetroShare the level is lowered to 0. The system crypto-policies
# policy for other programs is not affected; for RetroShare itself this file
# replaces the system openssl.cnf entirely.
# SHA-1 signing is additionally allowed by the variable
# OPENSSL_ENABLE_SHA1_SIGNATURES=1 (set by the wrapper).
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
info "Source1–Source3 created ✓"

# =============================================================================
# 4. SPEC FILE AND BUILDREQUIRES
# =============================================================================
step "4/6  retroshare.spec"
SPEC_FILE="$TOPDIR/SPECS/retroshare.spec"
# The date in %changelog is the commit date, so the spec does not change from run to run.
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
# The expression was composed by hand from the upstream COPYING (AGPL-3.0-only —
# main code; LGPL-3.0-or-later — libretroshare and libbitdht; GPL-3.0-or-later — GUI;
# BSD-3-Clause — TorControl; MIT — PictureFlow) and from the licenses of the
# bundled libraries (librnp: BSD-2-Clause and Apache-2.0; libsam3, udp-discovery-cpp,
# rapidjson: MIT; restbed: AGPL). Not verified with a scanner: before publishing
# the package, check it against the sources (e.g. licensecheck -r).
License:        AGPL-3.0-only AND LGPL-3.0-or-later AND GPL-3.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Apache-2.0
URL:            https://retroshare.cc
# Source0 is built by the script from a git checkout together with submodules
# (GitHub archives do not contain them), so it cannot be downloaded by URL.
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
# FFmpeg: via pkg-config — both ffmpeg-free (Fedora) and RPM Fusion will do
BuildRequires:  pkgconfig(libavcodec)
BuildRequires:  pkgconfig(libavformat)
BuildRequires:  pkgconfig(libavutil)
BuildRequires:  pkgconfig(libswscale)

# Qt plugins loaded at runtime (not visible to the automatic dependency generator)
Requires:       qt6-qtsvg
Requires:       hicolor-icon-theme
Recommends:     qt6-qtwayland

# Libraries that the build takes from supportlibs and links statically
Provides:       bundled(libsam3)
Provides:       bundled(librnp)
Provides:       bundled(restbed)
Provides:       bundled(udp-discovery-cpp)
# The plugins always take the rapidjson headers from supportlibs, while libretroshare
# uses the system ones (rapidjson-devel) if pkg-config finds them.
Provides:       bundled(rapidjson) = 1.1.0

%description
RetroShare is a decentralized, encrypted friend-to-friend platform: chat,
forums, channels, file sharing and voice/video, with no central server.

This package ships a launcher that enables SHA-1 signature compatibility
for the RetroShare process only (OPENSSL_ENABLE_SHA1_SIGNATURES and
/etc/retroshare/openssl-rs.cnf), leaving the system crypto policy intact.

%prep
%autosetup -n %{name}-%{version}

# The tarball has no .git, so libretroshare.pro substitutes the placeholder
# "[version not available]" into RS_LIB_VERSION_HASH. The spaces in it are
# invalid in a -DRS_LIB_VERSION_HASH=... value: the placeholder is replaced
# with the commit hash, after which it is verified that none are left.
grep -rlF '[version not available]' --include='*.pro' --include='*.pri' . \
    | xargs -r sed -i 's|\[version not available\]|%{commit}|g'
if grep -rF '[version not available]' --include='*.pro' --include='*.pri' . ; then
    echo "ERROR: version placeholder with spaces is still present in .pro/.pri" >&2
    exit 1
fi

# The librnp_header rule in libretroshare.pro calls
# `git submodule update --init src/libsexpp`, but the tarball has no .git.
# The submodules are already unpacked in Source0, so the `submodule`
# subcommand is a no-op via a shim in PATH; all other git calls run as usual.
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

# libsam3 (supportlibs) is built by its own Makefile with `CFLAGS := ...`: such an
# assignment overrides CFLAGS from the environment, while CC and the targets are
# hard-coded in libretroshare.pro. The static libsam3.a needs -fPIC (linking into
# Fedora's PIE binaries). The only variable this Makefile takes from the
# environment and inserts into the compile line is LDFLAGS; -fPIC is
# harmless there for the other link steps as well. The default value
# (build_ldflags) is preserved explicitly: the qmake_qt6 macro substitutes it
# only if LDFLAGS is not set.
export LDFLAGS="${LDFLAGS:-%{build_ldflags}} -fPIC"

# The plugins (FeedReader and others) take the bundled supportlibs/rapidjson 1.1.0
# via a plain -I, not -isystem, and GCC 16 treats -Wtemplate-body in it as an
# error. Exactly this diagnostic is disabled; the sources are not changed.
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

# Layout: the real binaries live in libexec (RS_BIN_DIR), while /usr/bin
# holds a wrapper that sets the OpenSSL environment. If upstream put a binary
# in the wrong place, the wrapper would overwrite it or point to nothing, so
# the layout is checked explicitly.
test -x %{buildroot}%{_libexecdir}/retroshare/retroshare || {
    echo "ERROR: %{_libexecdir}/retroshare/retroshare is missing — RS_BIN_DIR did not take effect" >&2
    exit 1
}
test ! -e %{buildroot}%{_bindir}/retroshare || {
    echo "ERROR: upstream already installed %{_bindir}/retroshare, the wrapper would overwrite it" >&2
    exit 1
}

install -Dpm0755 %{SOURCE1} %{buildroot}%{_bindir}/retroshare
sed -i -e 's|__LIBEXECDIR__|%{_libexecdir}|g' \
       -e 's|__SYSCONFDIR__|%{_sysconfdir}|g' %{buildroot}%{_bindir}/retroshare
if grep -q '__[A-Z]\+__' %{buildroot}%{_bindir}/retroshare; then
    echo "ERROR: unsubstituted markers remain in the wrapper" >&2
    exit 1
fi
# retroshare-service is the same wrapper under a different name (the wrapper
# runs the same-named file from libexec); created only if it was built.
if [ -x %{buildroot}%{_libexecdir}/retroshare/retroshare-service ]; then
    ln -s retroshare %{buildroot}%{_bindir}/retroshare-service
fi

install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/retroshare/openssl-rs.cnf

# Desktop entry: our own file (Source3). desktop-file-install validates it and
# aborts the build on error; the same-named upstream file is replaced.
desktop-file-install --dir=%{buildroot}%{_datadir}/applications %{SOURCE3}

# hicolor icons: upstream installs the raster sizes (we check), but not the svg.
for size in 24x24 48x48 64x64 128x128; do
    test -f %{buildroot}%{_datadir}/icons/hicolor/$size/apps/retroshare.png || {
        echo "ERROR: upstream did not install the $size icon" >&2
        exit 1
    }
done
install -Dpm0644 data/retroshare.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/retroshare.svg

# File list: everything installed by upstream `make install`, plus the package's
# own files. An explicit list is not used: the layout depends on the qmake flags
# and the upstream version. %%dir is applied only to directories owned by
# this package (shared ones like /usr/share/applications are not touched);
# files in /etc are marked as configuration.
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
    error "Unsubstituted markers remain in the spec:"; echo "$LEFT" >&2
    exit 1
fi
info "Spec: $SPEC_FILE ✓"

if [ "${SKIP_DEPS:-0}" != "1" ]; then
    info "Installing BuildRequires (dnf builddep)..."
    sudo dnf builddep -y "$SPEC_FILE"
fi

# =============================================================================
# 5. BUILD
# =============================================================================
step "5/6  rpmbuild -ba"
# Number of threads: LTO (-flto=auto) + -O2 need ~2 GB of RAM per cc1plus,
# and when memory runs short the OOM-killer kills the compiler.
if [ -z "${RS_JOBS:-}" ]; then
    MEM_GB=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
    RS_JOBS=$(( MEM_GB / 2 )); [ "$RS_JOBS" -ge 1 ] || RS_JOBS=1
    [ "$RS_JOBS" -le "$(nproc)" ] || RS_JOBS="$(nproc)"
fi
[[ "$RS_JOBS" =~ ^[1-9][0-9]*$ ]] || { error "RS_JOBS='$RS_JOBS': an integer > 0 is required"; exit 1; }
info "Build threads: $RS_JOBS (RS_JOBS=N to change)"

RPMBUILD_ARGS=(--define "_topdir $TOPDIR" --define "_smp_mflags -j${RS_JOBS}")
if [ "${RS_NODEBUG:-0}" = "1" ]; then
    info "RS_NODEBUG=1 — debuginfo/debugsource will not be created"
    RPMBUILD_ARGS+=(--define 'debug_package %{nil}')
fi

if ! rpmbuild -ba "${RPMBUILD_ARGS[@]}" "$SPEC_FILE" 2>&1 | tee "$LOGDIR/rpmbuild.log"; then
    error "rpmbuild failed, full log: $LOGDIR/rpmbuild.log"
    # In a parallel build the cause of the failure is usually in the middle of the log, not at the end.
    warn "Probable causes (first matches):"
    grep -nE 'error:|Error [0-9]+|\*\*\*|undefined reference|Killed signal|fatal error' \
        "$LOGDIR/rpmbuild.log" | grep -vE 'Werror=format-security|warning:' | head -n 30 || true
    exit 1
fi

# =============================================================================
# 6. VERIFICATION AND RESULT
# =============================================================================
step "6/6  Result"
mapfile -t BUILT < <(find "$TOPDIR/RPMS" "$TOPDIR/SRPMS" -name "retroshare*-${VERSION}-${RELEASE}.*.rpm" | sort)
[ "${#BUILT[@]}" -gt 0 ] || { error "No RPMs found in $TOPDIR"; exit 1; }

MAIN_RPM=""
for f in "${BUILT[@]}"; do
    if [ "$(rpm_kind "$f")" = "main" ]; then MAIN_RPM="$f"; break; fi
done
[ -n "$MAIN_RPM" ] || { error "Main package not found among the built ones"; exit 1; }

info "Package contents:";  rpm -qlp "$MAIN_RPM" | sed 's/^/    /'
info "Dependencies:";      rpm -qRp "$MAIN_RPM" | sed 's/^/    /'

# Mandatory contents: wrapper, real binary, config, desktop entry and icon
# (without the desktop entry and icon GNOME will not show the app in search).
# The list is read once: "rpm | grep -q" under pipefail gives a false error (SIGPIPE).
PKG_FILES="$(rpm -qlp "$MAIN_RPM")"
for need in '^/usr/bin/retroshare$' \
            '^/usr/libexec/retroshare/retroshare$' \
            '^/etc/retroshare/openssl-rs\.cnf$' \
            '^/usr/share/applications/retroshare\.desktop$' \
            '^/usr/share/icons/hicolor/[^/]+/apps/retroshare\.(png|svg)$'; do
    grep -qE "$need" <<<"$PKG_FILES" \
        || { error "The package has no file matching the pattern: $need"; exit 1; }
done

# Upstream does not install headers or static libraries. If they show up in
# the list, the layout has changed and the package needs to be split into -devel/-static.
if DEVFILES="$(grep -E '^/usr/include/|\.a$' <<<"$PKG_FILES")"; then
    warn "The retroshare package contains development files (candidates for -devel/-static):"
    echo "$DEVFILES" | head -n 10 | sed 's/^/    /'
fi
if command -v rpmlint >/dev/null 2>&1; then
    info "rpmlint:"; rpmlint "$MAIN_RPM" || true
fi

echo -e "\n${GREEN}Done:${NC}"
for f in "${BUILT[@]}"; do
    case "$(rpm_kind "$f")" in
        debuginfo)   role="debug symbols (for gdb/ABRT, optional)" ;;
        debugsource) role="sources for debugging (optional)" ;;
        srpm)        role="source package (SRPM)" ;;
        main)        role="main package — this is the one to install" ;;
    esac
    printf '  %s\n      %s\n' "$f" "$role"
done
echo -e "\nInstall:    sudo dnf install $MAIN_RPM"
echo "Run:        retroshare"
