# FreeBSD port: `sysutils/install-fbsd-desktop`

This directory is a **ports-tree ready** skeleton for packaging `installx`.

**Maintainer:** Nicholas Bernstein <install-fbsd-desktop@nicholasbernstein.com>

| Path | Role |
|------|------|
| `sysutils/install-fbsd-desktop/Makefile` | Port definition |
| `sysutils/install-fbsd-desktop/pkg-descr` | Package description |
| `sysutils/install-fbsd-desktop/pkg-plist` | Packing list |
| `sysutils/install-fbsd-desktop/distinfo` | Checksums for GitHub fetches (`make makesum`) |

Installed files (default `PREFIX=/usr/local`):

| Path | Description |
|------|-------------|
| `sbin/installx` | Main installer script |
| `sbin/install-fbsd-desktop` | Symlink to `installx` |
| `share/install-fbsd-desktop/test_installx.sh` | Post-install shunit2 tests |
| `share/install-fbsd-desktop/shunit2` | Test framework |
| `share/doc/install-fbsd-desktop/ReadMe.md` | Docs (if `DOCS` option on) |

## Build from this git checkout (FreeBSD)

Local mode copies `installx.sh` and friends from the monorepo root — no distfile download:

```sh
cd ports/sysutils/install-fbsd-desktop
make package
# or:
make install clean
```

Then:

```sh
pkg install ./work/pkg/install-fbsd-desktop-0.2.0.pkg   # path may vary
# or after make install:
sudo installx
```

## Install into the system ports tree

```sh
# from the repo root
cp -a ports/sysutils/install-fbsd-desktop /usr/ports/sysutils/
cd /usr/ports/sysutils/install-fbsd-desktop
make install clean
```

If the port is copied **without** the parent monorepo, the Makefile switches to
`USE_GITHUB` automatically (or set `FORCE_GITHUB=yes`).

## GitHub distfile / official package builds

```sh
cd ports/sysutils/install-fbsd-desktop
# After tagging a release (recommended):
#   git tag -a v0.2.0 -m "..."
#   # set DISTVERSION=0.2.0 and GH_TAGNAME=v0.2.0 (or rely on DISTVERSIONPREFIX=v)
make FORCE_GITHUB=yes makesum
make FORCE_GITHUB=yes package
```

Commit the updated `distinfo` whenever `GH_TAGNAME` / `DISTVERSION` changes.

## Runtime dependency

- `misc/dialog` — interactive menus (`pkg install dialog`)

`pkg`, `sysrc`, and `pw` come from FreeBSD base.
