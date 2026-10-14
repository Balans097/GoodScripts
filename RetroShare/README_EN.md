# MakeRetroShareRPM.sh

Builds an RPM package of [RetroShare](https://retroshare.cc) for Fedora (Qt6, OpenSSL 3.x) from git sources. The result is a package that installs with `dnf`, registers itself in the system (desktop entry, icons) and starts with the `retroshare` command.

## Quick start

```bash
./MakeRetroShareRPM.sh                    # master
RS_REF=v0.6.7.3 ./MakeRetroShareRPM.sh    # tag, branch or commit hash
sudo dnf install _rpmbuild/RPMS/x86_64/retroshare-*.rpm
retroshare
```

Requirements: Fedora, `sudo` and access to GitHub. The script installs `rpm-build`, `git`, `tar` and `gzip` itself, then installs all BuildRequires with `dnf builddep` using the generated spec.

## What the script does

1. **Tools.** Installs what the script itself needs.
2. **Sources.** Clones the repository, checks out `RS_REF`, fetches submodules and packs everything into `Source0` (tar.gz). The archive is built by hand: GitHub archives do not contain submodules, and RetroShare does not build without them. The archive is deterministic: file order, owner, mtime and the gzip header are fixed.
3. **Helper files.** Creates the launcher wrapper, the OpenSSL config and the `.desktop` file (Source1–Source3).
4. **Spec.** Generates `retroshare.spec` from a template and installs BuildRequires.
5. **Build.** `rpmbuild -ba`; the log goes to `_logs/rpmbuild.log`. The number of jobs is chosen from available memory (LTO needs about 2 GB per compiler process).
6. **Verification.** Checks that the package contains the wrapper, the binary, the config, the desktop entry and an icon; runs `rpmlint` if it is installed.

### Package version

- Build from a tag: `Version` = tag, `Release` = `1`.
- Build from a branch or commit: `Version` = nearest tag, `Release` = `1.<date>git<hash>` (post-release snapshot per the Fedora Packaging Guidelines).

### Resulting packages

| Package | Purpose |
|---|---|
| `retroshare` | Main package. The only one needed to run the application |
| `retroshare-debuginfo`, `retroshare-debugsource` | Symbols and sources for gdb, ABRT, coredumpctl. Created automatically; `RS_NODEBUG=1` disables them |
| `retroshare-*.src.rpm` | SRPM in `_rpmbuild/SRPMS/` |

RetroShare sources are not patched. The only change in `%prep` replaces the `[version not available]` placeholder in `.pro`/`.pri` files with the commit hash: the tarball has no `.git`, and the placeholder contains spaces, so it is not valid as a `-D…` value.

### Environment variables

| Variable | Meaning |
|---|---|
| `RS_REF` | branch, tag or commit hash (default `master`) |
| `RS_VERSION` | force `Version` |
| `RS_WORKDIR` | working directory (default: the script's directory) |
| `RS_JOBS` | number of build jobs |
| `RS_NODEBUG=1` | do not create debuginfo/debugsource |
| `SKIP_DEPS=1` | do not call `dnf` |
| `FORCE_RECLONE=1` | delete and re-clone the sources |
| `RPM_CHANGELOG_WHO` | `Name <email>` for `%changelog` |

## Why the binary is started through a wrapper

RetroShare uses SHA-1 in certificates and signatures, including those that users already have. On Fedora with OpenSSL 3 this does not work out of the box:

- OpenSSL 3 rejects SHA-1 already at security level `SECLEVEL=1`, and Fedora's default policy is stricter still;
- Fedora additionally restricts SHA-1 signatures through `crypto-policies`.

Relaxing the requirements system-wide (`update-crypto-policies --set LEGACY`) would weaken every other program. Patching RetroShare is not needed either: its code is compatible with the OpenSSL 1.1+/3 API. So the setup is done **through the environment of a single process**.

### Layout

```
/usr/bin/retroshare                 wrapper (sh script)
/usr/bin/retroshare-service         symlink to the wrapper (if built)
/usr/libexec/retroshare/retroshare  the real binary
/etc/retroshare/openssl-rs.cnf      OpenSSL config for RetroShare
```

The wrapper picks the binary by its own name (`${0##*/}`), so one script serves both `retroshare` and `retroshare-service`. The binary lives in `libexec` because `/usr/bin` is taken by the wrapper; the build verifies that upstream did not install its own file there.

### What the wrapper sets

| Variable | Effect |
|---|---|
| `OPENSSL_ENABLE_SHA1_SIGNATURES=1` | Downstream OpenSSL variable in Fedora/RHEL (upstream OpenSSL does not have it): allows SHA-1 signatures |
| `OPENSSL_CONF=/etc/retroshare/openssl-rs.cnf` | `SECLEVEL=0`, `MinProtocol=TLSv1.2`, the `default` provider |

Values already set by the user are not overwritten.

### Limitations

- For the RetroShare process, `openssl-rs.cnf` **fully replaces** the system `openssl.cnf`, including crypto-policies. Other programs are not affected.
- Environment variables are inherited by processes launched from RetroShare.
- The config is marked `%config(noreplace)`: local edits survive package updates.
- Running the binary directly (`/usr/libexec/retroshare/retroshare`) bypasses the setup, and SHA-1 will be rejected again.

## Desktop entry and icons

The desktop entry is installed by the spec, not by `make install`: the upstream file does not pass `desktop-file-validate` (obsolete `Encoding` key, icon name with an extension, absolute path in `Exec`, `Categories` without a trailing `;`). The package's own file is installed with `desktop-file-install`, which validates it and aborts the build on error. Raster hicolor icons are installed by upstream, the SVG by the spec. The RetroShare window has `app_id` `retroshare`, matching the `.desktop` file name, so GNOME associates the window with the entry without `StartupWMClass`.

## Known build limitations

- The `License` expression in the spec was composed by hand and has not been checked with a scanner; verify it (for example with `licensecheck -r`) before publishing the package.
- librnp, restbed, libsam3 and udp-discovery-cpp are linked statically from `supportlibs` (reflected in `Provides: bundled(...)`).
- The `-Wno-template-body` flag disables a GCC 16 diagnostic for the bundled rapidjson in plugins; the sources are not modified.

## Removal

```bash
sudo dnf remove retroshare retroshare-debuginfo retroshare-debugsource
```
