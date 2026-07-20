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

A ports skeleton lives under `ports/sysutils/install-fbsd-desktop/`
(maintainer: Nicholas Bernstein <install-fbsd-desktop@nicholasbernstein.com>).

On FreeBSD, from this checkout:

```sh
cd ports/sysutils/install-fbsd-desktop
make package          # or: make install clean
# then, if you built a package:
pkg install ./work/pkg/install-fbsd-desktop-*.pkg
```

That installs `installx` (and symlink `install-fbsd-desktop`) to `${PREFIX}/sbin`.
See `ports/README.md` for GitHub distfile builds and copying into `/usr/ports`.

## What gets installed

One menu lists desktops and compositors together. You pick what you want;
`installx.sh` applies a reasonable stack automatically:

| Choice | Session | Notes |
|--------|---------|--------|
| KDE, GNOME, Xfce4, MATE, Cinnamon, LXQt, LXDE, WindowMaker, awesome | X11 | xorg + sddm (gdm for GNOME) |
| Sway, Hyprland | Wayland | wayland + seatd + xwayland; ly greeter; config under `~/.config/` |

Wayland installs also write `~/start-desktop.sh` and enable `seatd`.

## CI / non-interactive install

Each desktop has its own GitHub Actions workflow under `.github/workflows/desktop-*.yml`.
They all call the shared runner in `smoketest-reusable.yml` (FreeBSD VM → noninteractive
`installx.sh` → `test_installx.sh`).

| Workflow | Desktop | On push | Weekly | Manual |
|----------|---------|---------|--------|--------|
| `desktop-awesome.yml` | awesome | yes | yes | yes |
| `desktop-windowmaker.yml` | WindowMaker | yes | yes | yes |
| `desktop-lxde.yml` | LXDE | yes | yes | yes |
| `desktop-lxqt.yml` | LXQT | yes | yes | yes |
| `desktop-xfce4.yml` | Xfce4 | yes | yes | yes |
| `desktop-sway.yml` | Sway (Wayland) | yes | yes | yes |
| `desktop-hyprland.yml` | Hyprland (Wayland) | yes | yes | yes |
| `desktop-mate.yml` | MATE | PR only | yes | yes |
| `desktop-cinnamon.yml` | Cinnamon | PR only | yes | yes |
| `desktop-kde.yml` | KDE | PR only | yes | yes |
| `desktop-gnome.yml` | GNOME | PR only | yes | yes |

Heavier DEs skip plain pushes so default CI stays lighter; re-run any
workflow from the Actions tab (`workflow_dispatch`).

Noninteractive env knobs (also used by CI):

```sh
export INSTALLX_NONINTERACTIVE=1   # or CI=true
export INSTALLX_USER=nick
export INSTALLX_DESKTOP=Sway       # any menu name, e.g. Cinnamon Hyprland awesome …
export INSTALLX_ROLLING=yes
export INSTALLX_EXTRA_PKGS="bash sudo"
export INSTALLX_GRAPHICS=no
# optional: INSTALLX_OPT="load_fuse enable_ipfw_firewall minimal_xorg ..."
sh installx.sh
sh test_installx.sh                # post-install checks (shunit2)
```

Youtube video demo:

[![Video showing how it works](https://img.youtube.com/vi/2Gv5bY77-j8/hqdefault.jpg)](https://www.youtube.com/watch?v=2Gv5bY77-j8)
