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

## CI / non-interactive install

GitHub Actions smoketests run weekly and on push (see `.github/workflows/smoketest.yml`).
They drive `installx.sh` without `dialog` menus:

```sh
export INSTALLX_NONINTERACTIVE=1   # or CI=true
export INSTALLX_USER=nick
export INSTALLX_DESKTOP=awesome    # KDE LXDE LXQT GNOME Xfce4 WindowMaker awesome MATE
export INSTALLX_ROLLING=yes
export INSTALLX_EXTRA_PKGS="bash sudo"
export INSTALLX_GRAPHICS=no
# optional: INSTALLX_OPT="load_fuse enable_ipfw_firewall minimal_xorg ..."
sh installx.sh
sh test_installx.sh                # post-install checks (shunit2)
```

Youtube video demo:

[![Video showing how it works](https://img.youtube.com/vi/2Gv5bY77-j8/hqdefault.jpg)](https://www.youtube.com/watch?v=2Gv5bY77-j8)
