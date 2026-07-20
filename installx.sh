#!/bin/sh
# Nick Bernstein https://github.com/nicholasbernstein/install-fbsd-desktop
# most of this comes from the freebsd handbook 5.4.1. Quick Start x-config
set -o pipefail
#set -e
set -x
PS4="$0 $LINENO >"

LOGFILE="installx.log"
ERRLOG="installx.err"
exec 2>"$ERRLOG"
date > "$LOGFILE"

# Non-interactive / CI mode: set INSTALLX_NONINTERACTIVE=1 (or CI=true).
# Optional env overrides:
#   INSTALLX_USER          user to add to video/wheel (default: uid 1001 or "nick")
#   INSTALLX_DESKTOP       desktop/compositor name (default: awesome)
#                          X11: KDE LXDE LXQT GNOME Xfce4 WindowMaker awesome MATE Cinnamon
#                          Wayland: Sway Hyprland  (same menu; stack is chosen automatically)
#   INSTALLX_ROLLING       yes|no — use pkg "latest" (default: yes)
#   INSTALLX_EXTRA_PKGS    space-separated packages (default: bash sudo)
#   INSTALLX_OPT           space-separated option names matching the dialog checklist (see below)
#   INSTALLX_GRAPHICS      yes|no — try to install GPU drivers (default: no)
#   INSTALLX_VIDEO_CARD    i915kms|radeonkms|amdgpu|nvidia|vesa|scfb (if GRAPHICS=yes)
#   INSTALLX_BASH_SHELL    yes|no — set user shell to bash (default: yes if bash installed)
#   INSTALLX_SUDO_WHEEL    yes|no — allow %wheel to sudo (default: yes if sudo installed)
#
# Each desktop sets a small profile (SESSION_TYPE, packages, display manager). The user only
# picks what they want; X11 vs Wayland plumbing is applied automatically.
is_noninteractive() {
	[ "${INSTALLX_NONINTERACTIVE:-0}" = "1" ] || [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]
}

# Avoid interactive pkg prompts (and OSVERSION skew) when driven by CI
if is_noninteractive ; then
	export ASSUME_ALWAYS_YES=yes
	export IGNORE_OSVERSION="${IGNORE_OSVERSION:-yes}"
fi

grep -q "kern.vty" /boot/loader.conf || echo "kern.vty=vt" >> /boot/loader.conf

change_pkg_url_to_latest () {
	sed -i 'orig' 's/quarterly/latest/' /etc/pkg/FreeBSD.conf
	grep url /etc/pkg/FreeBSD.conf
}

load_card_readers () {
	# Load MMC/SD card-reader support
	sysrc kld_list+="mmc"
	sysrc kld_list+="mmcsd"
	sysrc kld_list+="sdhci"
}

load_atapi() {
	# Access ATAPI devices through the CAM subsystem
	sysrc kld_list+="atapicam"
}

load_fuse() {
	# Filesystems in Userspace
	fuse_pkgs="fuse fuse-utils"
	extra_pkgs="$extra_pkgs fusefs-lkl e2fsprogs"
	sysrc kld_list+="fusefs"
}

load_coretemp(){
	# Intel Core thermal sensors
	sysrc kld_list+="coretemp"
}

load_amdtemp() {
	# AMD K8, K10, K11 thermal sensors
	if ( sysctl -a | grep -q -i "hw.model" | grep -q AMD ) ; then 
		amdtemp_load="YES"
	fi
}

load_bluetooth() { 
	# most common bluetooth adapters use this
	sysrc kld_list+="ng_ubt"
	sysrc hcsecd_enable="YES"
	sysrc sdpd_enable="YES"
}

enable_ipfw_firewall() {
	# this enables the ipfw firewall with the workstation profile
	# it allows communication w/ other hosts on the network, outgoing traffic
	# and any specific ports (ssh) we choose to enable
	sysrc firewall_type="WORKSTATION"
	sysrc firewall_myservices="22/tcp"
	sysrc firewall_allowservices="any"
	sysrc firewall_enable="YES"
}

enable_tmpfs() {
	# In-memory filesystems
	sysrc kld_list+="tmpfs"
}

enable_async_io() {
	# Asynchronous I/O
	sysrc kld_list+="aio"
}

enable_workstation_pwr_mgmnt() {
	# powerd: hiadaptive speed while on AC power, adaptive while on battery power
	sysrc powerd_enable="YES"
	sysrc powerd_flags="-a hiadaptive -b adaptive"
}

enable_webcam(){
	#this just enables the ability to use webcams
	extra_pkgs="$extra_pkgs webcamd"
	sysrc kld_list+="cuse4bsd"
	sysrc webcamd_enable="YES"
}

enable_cups() {
	#this just enables the ability to use printers
	extra_pkgs="$extra_pkgs cups"
	sysrc cupsd_enable="YES"
}


linuxBaseC7 () {
		sysrc kld_list+="linux"
		kldstat | grep -q linux || kldload linux
		sysrc kld_list+="linux64"
		kldstat | grep -q linux64 || kldload linux64
		sysrc linux_enable="YES"

		mkdir -p /compat/linux/proc /compat/linux/dev/shm /compat/linux/sys
		grep "/compat/linux/proc" /etc/fstab 2>/dev/null || \
			echo "linprocfs   /compat/linux/proc  linprocfs rw 0 0" >> /etc/fstab
		grep "/compat/linux/sys" /etc/fstab 2>/dev/null || \
			echo "linsysfs    /compat/linux/sys   linsysfs  rw 0 0" >> /etc/fstab
		grep "/compat/linux/dev" /etc/fstab 2>/dev/null || \
			echo "tmpfs    /compat/linux/dev/shm  tmpfs rw,mode=1777 0 0" >> /etc/fstab
}

enable_virtualbox_ose_additions() {
		sysrc vboxguest_enable="YES"
		sysrc vboxservice_enable="YES"
		if ! is_noninteractive ; then
			dialog --infobox "Please use VBoxSVGA as the virtualbox display driver for best performance." 0 0
		else
			echo "noninteractive: VirtualBox guest additions enabled; use VBoxSVGA for best performance." | tee -a "$LOGFILE"
		fi
}

adjust_sysctl_buffers() { 
	sysctl net.local.stream.recvspace=65536
	grep "net.local.stream.recvspace" /etc/sysctl.conf || echo "net.local.stream.recvspace=65536" >> /etc/sysctl.conf
	sysctl net.local.stream.sendspace=65536
	grep "net.local.stream.sendspace" /etc/sysctl.conf || echo "net.local.stream.sendspace=65536" >> /etc/sysctl.conf
}

report(){
	# $1 - testname, $2 - $?
        STATUS="OK"
        if [ "$2" -eq 1 ] ; then
                STATUS="FAILED"
        fi
        echo "$1: $STATUS" | tee -a $LOGFILE
}

# this is mainly just to make sure pkg has been bootstrapped
export ASSUME_ALWAYS_YES=yes
pkg update | tee -a "$LOGFILE"
report "pkg bootstrapping" "$?"

# this will help with performance of desktop applications
# and may help perf during install, so I'm doing it early
adjust_sysctl_buffers
report "add sync buffers" "$?"

add_user_to_video() {
	# Your user needs to be in the video group to use video acceleration
	default_user=`grep 1001 /etc/passwd | awk -F: '{ print $1 }'`
	if is_noninteractive ; then
		VUSER="${INSTALLX_USER:-${default_user:-nick}}"
		echo "noninteractive: using video user '$VUSER'" | tee -a "$LOGFILE"
	else
		VUSER=`dialog --title "Video User" --clear  --inputbox "What user should be added to the video group?" 0 0  $default_user --stdout`
	fi

	# ensure home exists for .xinitrc and similar
	if ! id "$VUSER" >/dev/null 2>&1 ; then
		echo "user '$VUSER' does not exist; creating" | tee -a "$LOGFILE"
		pw useradd -n "$VUSER" -m -s /bin/sh || true
	fi
	mkdir -p "/home/$VUSER"
	chown "$VUSER" "/home/$VUSER" 2>/dev/null || true

	pw groupmod video -m $VUSER && echo "added $VUSER to group: video"
	report "add $VUSER to video group" "$?"
	pw groupmod wheel -m $VUSER && echo "added $VUSER to group: wheel" 
	report "add $VUSER to wheel group" "$?"

	# probably not necessary, logging into an x session as root isn't recommended.
	pw groupmod video -m root
	report "add root to wheel group" "$?"
}

add_user_to_video

gen_xinit() {
	# the following creates a .xinitrc file in the user's home directory that will launch
	# the installed windowmanager as well as allow the slim display manager to pass it as
	# an argument. 
	if [ ! $1 ] ; then 
		echo "argument needed by gen_xinit" 
		return 0 
	else
		xinittxt="#!/bin/sh\n mywm="$1"\n if [ \$1 ] ; then\n \tcase \$1 in \n \t\tdefault) exec \$mywm ;;\n \t\t*) exec \$1 ;;\n \tesac\n else\n \texec \$mywm\n fi"
		#echo -e $xinittxt > /home/$VUSER/.xinitrc && chown $VUSER:$VUSER /home/$VUSER/.xinitrc
		echo -e $xinittxt > /home/$VUSER/.xinitrc && chown $VUSER /home/$VUSER/.xinitrc
		test -d /etc/skel || mkdir /etc/skel
		echo -e $xinittxt > /etc/skel/.xinitrc
	fi
}


# --- Session profile defaults (overridden per desktop below) ---
# User picks one desktop from a single menu; we apply a reasonable stack.
SESSION_TYPE="x11"          # x11 | wayland
NEED_XORG="yes"             # install xorg stack
SEATD_NEEDED="no"           # wayland compositors need seatd
DISPLAY_MGR="sddm"          # sddm | slim | gdm | ly | none
DESKTOP_PKGS=""
WAYLAND_COMPOSITOR=""       # sway | hyprland | ...
slim_extra_pkgs=""

# FreeBSD 11 used slim; keep that default for old releases
if ( uname -r | grep -q "^11" ) ; then
	DISPLAY_MGR="slim"
	slim_extra_pkgs="slim-freebsd-dark-theme"
	pwd_mkdb -p /etc/master.passwd
fi

seed_sway_config() {
	uhome="/home/${VUSER}"
	mkdir -p "${uhome}/.config/sway" /etc/skel/.config/sway
	if [ -f /usr/local/etc/sway/config ] ; then
		cp /usr/local/etc/sway/config "${uhome}/.config/sway/config"
		cp /usr/local/etc/sway/config /etc/skel/.config/sway/config
	else
		cat > "${uhome}/.config/sway/config" <<'SWAYEOF'
# Minimal Sway config generated by installx.sh
set $mod Mod4
set $term alacritty
bindsym $mod+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -b 'Yes' 'swaymsg exit'
output * bg #222222 solid_color
SWAYEOF
		cp "${uhome}/.config/sway/config" /etc/skel/.config/sway/config
	fi
	chown -R "${VUSER}" "${uhome}/.config"
}

seed_hyprland_config() {
	uhome="/home/${VUSER}"
	mkdir -p "${uhome}/.config/hypr" /etc/skel/.config/hypr
	if [ -f /usr/local/share/hyprland/hyprland.conf ] ; then
		cp /usr/local/share/hyprland/hyprland.conf "${uhome}/.config/hypr/hyprland.conf"
	elif [ -f /usr/local/share/examples/hyprland/hyprland.conf ] ; then
		cp /usr/local/share/examples/hyprland/hyprland.conf "${uhome}/.config/hypr/hyprland.conf"
	else
		cat > "${uhome}/.config/hypr/hyprland.conf" <<'HYPREOF'
# Minimal Hyprland config generated by installx.sh
monitor=,preferred,auto,1
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
input {
    kb_layout = us
    follow_mouse = 1
}
general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
}
bind = SUPER, Return, exec, alacritty
bind = SUPER, Q, killactive,
bind = SUPER, M, exit,
HYPREOF
	fi
	cp "${uhome}/.config/hypr/hyprland.conf" /etc/skel/.config/hypr/hyprland.conf 2>/dev/null || true
	chown -R "${VUSER}" "${uhome}/.config"
}

setup_ly_greeter() {
	# TUI greeter that can start X11 and Wayland sessions (see handbook Wayland chapter)
	if [ ! -x /usr/local/bin/ly ] ; then
		echo "ly not installed; skip greeter setup" | tee -a "$LOGFILE"
		return 0
	fi
	if ! grep -q '^Ly:' /etc/gettytab 2>/dev/null ; then
		cat >> /etc/gettytab <<'GETTYEOF'

# installx.sh — ly greeter
Ly:\
	:lo=/usr/local/bin/ly:\
	:al=:
GETTYEOF
	fi
	if [ -f /etc/ttys ] && grep -q '^ttyv1' /etc/ttys ; then
		cp /etc/ttys /etc/ttys.installx.bak 2>/dev/null || true
		# shellcheck disable=SC2016
		sed -i '' -e 's|^ttyv1.*|ttyv1	"/usr/libexec/getty Ly"	xterm	on  secure|' /etc/ttys
		echo "configured ly on ttyv1 (backup: /etc/ttys.installx.bak)" | tee -a "$LOGFILE"
	fi
}

write_wayland_start_helper() {
	uhome="/home/${VUSER}"
	comp="${1:-$WAYLAND_COMPOSITOR}"
	cat > "${uhome}/start-desktop.sh" <<EOF
#!/bin/sh
# Generated by installx.sh — start the installed Wayland compositor
exec ${comp}
EOF
	chmod +x "${uhome}/start-desktop.sh"
	chown "${VUSER}" "${uhome}/start-desktop.sh"
	# skel for new users
	mkdir -p /etc/skel
	cp "${uhome}/start-desktop.sh" /etc/skel/start-desktop.sh
	chmod +x /etc/skel/start-desktop.sh
}

apply_display_manager() {
	case "$DISPLAY_MGR" in
		sddm|slim|gdm)
			sysrc "${DISPLAY_MGR}_enable"="YES"
			echo "display manager enabled: $DISPLAY_MGR" | tee -a "$LOGFILE"
			;;
		ly)
			# getty integration happens post-pkg in setup_ly_greeter
			echo "display manager: ly (configured after package install)" | tee -a "$LOGFILE"
			;;
		none|"")
			echo "display manager: none (start session manually)" | tee -a "$LOGFILE"
			;;
		*)
			echo "unknown DISPLAY_MGR=$DISPLAY_MGR" | tee -a "$LOGFILE"
			;;
	esac
}

if is_noninteractive ; then
	case "${INSTALLX_ROLLING:-yes}" in
		[Nn][Oo]|0|false|FALSE) rolling=1 ;;
		*) rolling=0 ;;
	esac
	echo "noninteractive: rolling(latest pkg)=$( [ "$rolling" -eq 0 ] && echo yes || echo no )" | tee -a "$LOGFILE"
else
	dialog --title "Rolling Release" --yesno "Change pkg to use 'latest' packages instead of quarterly? Recommended for workstations. This prevents potential missing firefox package in 13.1 quarterly" 0 0
	rolling=$?
fi

if [ "$rolling" -eq 0  ] ; then 
	change_pkg_url_to_latest
	report "quarterly->latest changed" "$?"
fi


if is_noninteractive ; then
	desktop="${INSTALLX_DESKTOP:-awesome}"
	echo "noninteractive: desktop=$desktop" | tee -a "$LOGFILE"
else
	desktop=$(dialog --clear --title "Select Desktop" \
	        --menu "Select desktop environment or compositor to install:\n(X11 and Wayland options are listed together; setup is chosen automatically.)" 0 0 0 \
	        "KDE"  "KDE Plasma (X11)" \
	        "GNOME" "GNOME desktop (X11)" \
	        "Xfce4" "Lightweight XFCE desktop (X11)" \
	        "MATE"  "MATE desktop, GNOME 2 fork (X11)" \
	        "Cinnamon" "Cinnamon desktop (X11)" \
	        "LXQT" "Lightweight Qt desktop (X11)" \
	        "LXDE"  "Lightweight X11 desktop (X11)" \
	        "WindowMaker" "Window Maker (X11)" \
	        "awesome" "Awesome tiling WM (X11)" \
	        "Sway" "Sway tiling compositor (Wayland)" \
	        "Hyprland" "Hyprland compositor (Wayland)" \
	        --stdout)
fi

# Normalize so dialog labels (WindowMaker, Xfce4, …) and CI env vars match.
desktop_key=$(echo "$desktop" | tr '[:upper:]' '[:lower:]')

case $desktop_key in
  kde)
      gen_xinit "startkde"
      DESKTOP_PKGS="kde5 plasma5-plasma plasma5-plasma-disks plasma5-plasma-systemmonitor kde-baseapps"
      DISPLAY_MGR="sddm"
      ;;
  windowmaker)
      gen_xinit "/usr/local/bin/wmaker"
      DESKTOP_PKGS="windowmaker wmakerconf"
      DISPLAY_MGR="sddm"
      mkdir -p /usr/local/share/xsessions
cat <<EOT >/usr/local/share/xsessions/wmaker.desktop
[Desktop Entry]
Encoding=UTF-8
Name=Windowmaker
Comment=Windowmaker Desktop Environment
Exec=/usr/local/bin/wmaker
Icon=
Type=Application
EOT
      ;;
  lxqt)
      gen_xinit "startlxqt"
      DESKTOP_PKGS="lxqt"
      DISPLAY_MGR="sddm"
      ;;
  lxde)
      gen_xinit "startlxde"
      DESKTOP_PKGS="lxde-meta lxde-common"
      DISPLAY_MGR="sddm"
      ;;
  gnome)
      gen_xinit "gnome-session"
      DESKTOP_PKGS="gnome"
      DISPLAY_MGR="gdm"
      sysrc gnome_enable="YES"
      ;;
  xfce4|xfce)
      gen_xinit "startxfce4"
      DESKTOP_PKGS="xfce xfce4-goodies"
      DISPLAY_MGR="sddm"
      ;;
  mate)
      gen_xinit "mate-session"
      DESKTOP_PKGS="mate"
      DISPLAY_MGR="sddm"
      ;;
  cinnamon)
      gen_xinit "cinnamon-session"
      DESKTOP_PKGS="cinnamon"
      DISPLAY_MGR="sddm"
      ;;
  awesome)
      gen_xinit "awesome"
      DESKTOP_PKGS="awesome"
      DISPLAY_MGR="sddm"
      ;;
  sway)
      SESSION_TYPE="wayland"
      NEED_XORG="no"
      SEATD_NEEDED="yes"
      DISPLAY_MGR="ly"
      WAYLAND_COMPOSITOR="sway"
      DESKTOP_PKGS="sway swayidle swaylock-effects alacritty waybar"
      ;;
  hyprland)
      SESSION_TYPE="wayland"
      NEED_XORG="no"
      SEATD_NEEDED="yes"
      DISPLAY_MGR="ly"
      WAYLAND_COMPOSITOR="hyprland"
      DESKTOP_PKGS="hyprland alacritty"
      ;;
  *)
     echo "$desktop isn't a valid option."
     if is_noninteractive ; then
       exit 1
     fi
     ;;
esac

echo "profile: desktop=$desktop_key session=$SESSION_TYPE display_mgr=$DISPLAY_MGR need_xorg=$NEED_XORG" | tee -a "$LOGFILE"
apply_display_manager
report "Desktop Selected" "$?"

# The following are generally needed by most modern desktops
sysrc dbus_enable="YES"
report "DBus Enabled" "$?"
grep "proc /proc procfs" /etc/fstab || echo "proc /proc procfs rw 0 0" >> /etc/fstab

# A number of the more lightweight desktops don't include everything you need
# and anyone coming from linux probably wants bash, sudo & vim. Let's make
# the transition easy for them
if is_noninteractive ; then
	# Keep the default extras small for CI; override with INSTALLX_EXTRA_PKGS
	extra_pkgs="${INSTALLX_EXTRA_PKGS-bash sudo}"
	echo "noninteractive: extra_pkgs=$extra_pkgs" | tee -a "$LOGFILE"
else
	extra_pkgs=$(dialog --checklist "Select additional packages to install:" 0 0 0 \
	firefox "Firefox Web browser" on \
	bash "GNU Bourne-Again SHell" on \
	vim "VI Improved" on \
	git-lite "Lightweight Git client" on \
	sudo "Superuser do" on \
	thunderbird "Thunderbird Email Client" off \
	obs-studio "OBS-Studio recording/casting" off \
	audacity "Audio editor" off \
	simplescreenrecorder "Does it need a description?" off \
	libreoffice "Open source office suite" off \
	vlc "Video player" off \
	doas "Simpler alternative to sudo" off \
	linux_base-c7 "CentOS v7 linux binary compatiblity layer" off \
	virtualbox-ose-additions "VirtualBox guest additions" off \
	--stdout)
fi

echo "Extra packages:" "$extra_pkgs" | tee -a "$LOGFILE"


# by default install the full xorg, but if xorg_minimal is set, override it

echo $extra_pkgs | grep -q linux_base-c7 && linuxBaseC7
echo $extra_pkgs | grep -q virtualbox-ose-additions && enable_virtualbox_ose_additions

# Honestly, shouldn't graphic card configuration be done in the base installer? 
# Even if X isn't enabled, the right drivers should be selected and installed.
# Lets handle the 4 major cases, and hope for the best

if is_noninteractive ; then
	case "${INSTALLX_GRAPHICS:-no}" in
		[Yy][Ee][Ss]|1|true|TRUE) install_dv_drivers=0 ;;
		*) install_dv_drivers=1 ;;
	esac
else
	dialog --title "Graphics Drivers" --yesno "Would you like to try to install the drivers for your video card?\n\nPlease refer to freebsd handbook for more details:\nhttps://www.freebsd.org/doc/handbook/x-config.html" 0 0
	install_dv_drivers=$?
fi

if [ "$install_dv_drivers" -eq 0  ] ; then 

	if is_noninteractive ; then
		card="${INSTALLX_VIDEO_CARD:-}"
	else
		card=$(dialog --checklist "Select additional packages to install:" 0 0 0 \
		i915kms "most Intel graphics cards" off \
		radeonkms "most OLDER Radeon graphics cards" off \
		amdgpu "most NEWER AMD graphics cards" off \
		nvidia "NVidia Graphics Cards" off \
		vesa 	"Generic driver that may work as a fallback" off \
		scfb 	"Another Generic diver for UEFI and ARM" off \
		other "Anything but the above" off \
		--stdout)
	fi

	case $card in
		i915kms) 
			vc_pkgs="drm-kmod"
			sysrc kld_list+="/boot/modules/i915kms.ko"
			;;
		radeonkms) 
			vc_pkgs="drm-kmod xf86-video-ati"
			sysrc kld_list+="/boot/modules/radeonkms.ko"
			;;
		amdgpu) 
			vc_pkgs="drm-kmod xf86-video-amdgpu"
			sysrc kld_list+="amdgpu"
			;;
		nvidia) 
			vc_pkgs="nvidia-driver nvidia-xconfig nvidia-settings"
			nvidia-xconfig
			sysrc kld_list+="nvidia-modeset nvidia"
			;;
		vesa)
			vc_pkgs="xf86-video-vesa"
			;;
		scfb)
			vc_pkgs="xf86-video-scfb"
			;;
		*)
			pciconf=$(pciconf -vl | grep -B3 display)
			if ! is_noninteractive ; then
				dialog --msgbox "You'll need to check the FreeBSD handbook or forums. The following output may be helpful in finding a driber: pciconf -vl | grep -B3 display: $pciconf" 0 0
			else
				echo "noninteractive: no known video card selected; pciconf: $pciconf" | tee -a "$LOGFILE"
			fi
			;;
	esac

fi 

# This is opt activities — must run before package list is finalized
if is_noninteractive ; then
	# Defaults chosen so existing shunit2 checks (fuse, ipfw, minimal footprint) pass in CI
	opt_activities="${INSTALLX_OPT:-load_card_readers load_atapi load_fuse enable_tmpfs enable_async_io enable_workstation_pwr_mgmnt enable_ipfw_firewall minimal_xorg}"
	echo "noninteractive: opt_activities=$opt_activities" | tee -a "$LOGFILE"
else
	opt_activities=$(dialog --checklist "Select additional options" 0 0 0 \
		load_card_readers "enable card readers like sd cards" on \
		load_atapi "enable atapi to enable external storage devices like cds" on \
		load_fuse "enable userspace fileystems" on \
		load_coretemp "enable cpu temp sensors for intel (and amd)" off \
		load_amdtemp "enable additional amd temp sensors" off \
		enable_tmpfs "enable in-mem tempfs" on \
		enable_cups "printing" off \
		enable_webcam "enables webcams to be used" off \
		enable_ipfw_firewall "enables workstation firewall profile + allow ssh" off \
		enable_async_io "enable async io for better perf" on \
		enable_workstation_pwr_mgmnt "change pwr on battery/plugged in" on \
		load_bluetooth "enable bluetooth kernel modules" off \
		minimal_xorg "only install minimal xorg packages" off \
		--stdout )
fi

#
# this comment is just to draw attention to
# the fact that this line is doing the package installs
# and making it easy to find by having a big comment block
# above it
#
xorg_minimal="xorg-minimal xauth xorg-libraries xorg-fonts xorg-fonts-truetype xf86-input-keyboard xf86-input-libinput xf86-input-mouse"
xorg_pkgs="xorg"
# Wayland stack: compositor packages come from DESKTOP_PKGS; this is shared plumbing
wayland_base_pkgs="wayland seatd xwayland"

echo $opt_activities | grep -q load_card_readers && load_card_readers
echo $opt_activities | grep -q load_atapi && load_card_readers
echo $opt_activities | grep -q load_fuse && load_fuse
echo $opt_activities | grep -q load_coretemp && load_card_readers
echo $opt_activities | grep -q load_amdtemp && load_card_readers
echo $opt_activities | grep -q load_bluetooth && load_card_readers
echo $opt_activities | grep -q enable_ipfw_firewall && enable_ipfw_firewall
echo $opt_activities | grep -q enable_tmpfs && enable_tmpfs
echo $opt_activities | grep -q enable_async_io && enable_async_io
echo $opt_activities | grep -q enable_workstation_pwr_mgmnt && enable_workstation_pwr_mgmnt
echo $opt_activities | grep -q load_bluetooth && load_bluetooth
echo $opt_activities | grep -q enable_cups && enable_cups
echo $opt_activities | grep -q enable_webcam && enable_webcam

# Display stack: full/minimal Xorg for X11 sessions; wayland+seatd+xwayland for compositors
if [ "$NEED_XORG" = "yes" ] ; then
	echo $opt_activities | grep -q minimal_xorg && xorg_pkgs=$xorg_minimal
	display_stack="$xorg_pkgs"
else
	display_stack="$wayland_base_pkgs"
	echo "session is Wayland; skipping Xorg metapackage (using: $display_stack)" | tee -a "$LOGFILE"
fi

# Display manager package (empty if none)
dm_pkgs=""
case "$DISPLAY_MGR" in
	sddm|slim|gdm|ly) dm_pkgs="$DISPLAY_MGR" ;;
esac

# Final package list for install
all_pkgs="$display_stack dbus $DESKTOP_PKGS $extra_pkgs $vc_pkgs $dm_pkgs $slim_extra_pkgs"

# check to see if we should set the user shell to bash
# (moved after all_pkgs is known; previously referenced all_pkgs before it was set)
if ( echo "$all_pkgs" | grep -q "bash" ) ; then
	if is_noninteractive ; then
		case "${INSTALLX_BASH_SHELL:-yes}" in
			[Nn][Oo]|0|false|FALSE) bash_yes=1 ;;
			*) bash_yes=0 ;;
		esac
	else
		dialog --title "Bash" --yesno "Would you like to set the $VUSER user's default shell to bash?" --stdout 0 0
		bash_yes=$?
	fi
fi

# check to see if we should allow %wheel to sudo
if ( echo "$all_pkgs" | grep -q "sudo" ) ; then
	if is_noninteractive ; then
		case "${INSTALLX_SUDO_WHEEL:-yes}" in
			[Nn][Oo]|0|false|FALSE) sudo_yes=1 ;;
			*) sudo_yes=0 ;;
		esac
	else
		dialog --title "sudo" --yesno "Would you like to make sudo act like the default behavior on linux?\n(wheel group can sudo)" --stdout 0 0
		sudo_yes=$?
	fi
fi

echo "pkg install -y $all_pkgs" | tee -a "$LOGFILE"
pkg install -y $all_pkgs | tee -a "$LOGFILE"
pkg_status=$?
report "package installation: " "$pkg_status"
if [ "$pkg_status" -ne 0 ] && is_noninteractive ; then
	echo "FATAL: package installation failed in noninteractive mode (status=$pkg_status)" | tee -a "$LOGFILE"
	exit 1
fi

# post install stuff
if [ "$DISPLAY_MGR" = "slim" ] ; then
	sed -i '' -E 's/^current_theme.+$/current_theme		slim-freebsd-dark-theme/' /usr/local/etc/slim.conf
	report "slim.conf dark theme" "$?"
fi

# Wayland: seatd, compositor config, optional ly greeter, start helper
if [ "$SESSION_TYPE" = "wayland" ] ; then
	if [ "$SEATD_NEEDED" = "yes" ] ; then
		sysrc seatd_enable="YES"
		report "seatd enabled" "$?"
	fi
	case "$WAYLAND_COMPOSITOR" in
		sway) seed_sway_config ; report "sway config" "$?" ;;
		hyprland) seed_hyprland_config ; report "hyprland config" "$?" ;;
	esac
	write_wayland_start_helper "$WAYLAND_COMPOSITOR"
	report "wayland start helper" "$?"
	if [ "$DISPLAY_MGR" = "ly" ] ; then
		setup_ly_greeter
		report "ly greeter" "$?"
	fi
fi

# make sudo behave like default linux setup
if [ "${sudo_yes:-1}" -eq 0 ] ; then
	test -e /usr/local/etc/sudoers && echo "%wheel ALL=(ALL) ALL" >> /usr/local/etc/sudoers
	report "created sudoers for wheel" "$?"
fi

# on 11.x w/ mate re-installing fixed a core-dump
if [ "$desktop_key" = "mate" ] ; then 
	if ( echo $(uname -r) | grep -q "11" ) ; then 
		pkg install -f gsettings-desktop-schemas
	fi
fi

# Set the user's shell to bash
if [ "${bash_yes:-1}" -eq 0 ] ; then
	chpass -s /usr/local/bin/bash $VUSER || echo "failed to change shell to bash"
fi

if [ "$SESSION_TYPE" = "wayland" ] ; then
	welcome="Thanks for trying this setup script. You selected a Wayland compositor ($WAYLAND_COMPOSITOR). seatd is enabled and a starter script was written to /home/${VUSER}/start-desktop.sh. If ly was installed, use the greeter on ttyv1 after reboot; otherwise log in on the console and run: $WAYLAND_COMPOSITOR\n\nSee the FreeBSD handbook Wayland chapter for details. Report problems to http://bug.freebsddesktop.xyz/ or check installx.log."
else
	welcome="Thanks for trying this setup script. If you're new to FreeBSD, it's worth noting that instead of trying to search google for how to do something, you probably want to check the handbook on freebsd.org or read the built-in man pages. \n\n Doing a 'man -k <topic>' will search for any matching documentation, and unlike some, ahem, other *nix operating systems, FreeBSD's built in documentation is really good.\n\n"
fi
if is_noninteractive ; then
	echo "$welcome" | tee -a "$LOGFILE"
	echo "noninteractive install finished. See $LOGFILE and $ERRLOG" | tee -a "$LOGFILE"
else
	dialog --msgbox "$welcome Hopefully that worked. You'll probably want to reboot at this point. Please report any problems to http://bug.freebsddesktop.xyz/ or see the installx.log file created" 0 0
fi

