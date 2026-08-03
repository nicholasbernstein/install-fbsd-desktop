Strongly inspired by https://github.com/broozar/installDesktopFreeBSD

Run the script as the root use as follows you can use: 

```sh
fetch http://a.freebsddesktop.xyz -o installx.sh
sh installx.sh
```

or 

```sh
fetch https://raw.githubusercontent.com/nicholasbernstein/install-fbsd-desktop/main/installx.sh -o - | sh
```
...or not. You're a grownup. Make your own decisions about how you want to do things.

## FreeBSD port / package

A ports skeleton lives under `ports/sysutils/install-fbsd-desktop/`.
Full CI builds a `.pkg` and, after all smoketests pass, publishes GitHub
Release assets when installable content changes (rolling tag `latest`).

On FreeBSD, from this checkout:

```sh
sh scripts/build-freebsd-pkg.sh
# or via the port:
cd ports/sysutils/install-fbsd-desktop
make package          # or: make install clean
pkg install ./work/pkg/install-fbsd-desktop-*.pkg
```

That installs `installx` (and symlink `install-fbsd-desktop`) to `${PREFIX}/sbin`.
See `ports/README.md` for details.

## What gets installed

One menu lists desktops and compositors together. You pick what you want;
`installx.sh` applies a reasonable stack automatically:

| Choice | Session | Notes |
|--------|---------|--------|
| KDE, GNOME, Xfce4, MATE, Cinnamon, LXQt, LXDE, WindowMaker, awesome | X11 | xorg + sddm (gdm for GNOME) |
| Sway, Hyprland | Wayland | wayland + seatd + xwayland; ly greeter; `~/start-desktop.sh` for CLI |

Wayland installs also write `~/start-desktop.sh` and enable `seatd`.

## Testing

`installx.sh` is a **single-file** installer (download and run with nothing
else). Unit tests live in the repo for developers/CI only.

On FreeBSD, from a checkout:

```sh
sh tests/unit/test_installx_logic.sh   # pure helpers extracted from installx.sh
# after a noninteractive install:
sh test_installx.sh                    # post-install checks (shunit2)
```

## CI

One workflow runs **everything** on every push, weekly schedule, PR, or manual
dispatch (`.github/workflows/ci.yml`):

1. **Lint** — shell/python syntax and FreeBSD release discovery script  
2. **Unit tests** (FreeBSD VM) — `tests/unit/test_installx_logic.sh` (KDE/Plasma
   package resolution, catalog filters, handbook GPU selections)  
3. **Dialog UI smokes** (FreeBSD VM) — `scripts/test-dialog-ui.sh` (cdialog
   widgets) plus one expect run (`scripts/test-dialog-expect.exp`: welcome +
   Ctrl+C). Interactive installs `pkg install cdialog` on first run if needed.
4. **All desktop smokes** (in parallel) — each desktop × currently supported
   FreeBSD releases ([security.freebsd.org](https://www.freebsd.org/security/#sup),
   via `scripts/freebsd-supported-releases.py`)  
5. **Package build** (in parallel with smokes) — `.pkg`, `installx.sh`, ports tarball  
6. **Release** — only if **all** of the above succeeded **and** `CONTENT_SHA256`
   differs from the current `latest` release (otherwise skip publish)

Desktops covered: awesome, WindowMaker, LXDE, LXQT, Xfce4, Sway, Hyprland,
MATE, Cinnamon, KDE, GNOME.

Noninteractive env knobs (also used by CI):

```sh
export INSTALLX_NONINTERACTIVE=1   # or CI=true
export INSTALLX_USER=nick
export INSTALLX_DESKTOP=Sway       # any menu name, e.g. Cinnamon Hyprland awesome …
# INSTALLX_ROLLING=no  (default path) forces quarterly even if the image
#   already points at latest; =yes switches to latest. Preview branches may
#   still prefer latest when ROLLING is unset.
export INSTALLX_EXTRA_PKGS="bash sudo"
export INSTALLX_GRAPHICS=no
# optional: INSTALLX_OPT="load_fuse enable_ipfw_firewall minimal_xorg ..."
sh installx.sh
sh test_installx.sh                # post-install checks (shunit2)
```

Youtube video demo:

[![Video showing how it works](https://img.youtube.com/vi/2Gv5bY77-j8/hqdefault.jpg)](https://www.youtube.com/watch?v=2Gv5bY77-j8)
