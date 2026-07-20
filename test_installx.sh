#!/bin/sh
# file: test_installx.sh — post-install checks for installx.sh

testuser="nick"
tuhome="/home/${testuser}"

test_vt_in_loader() {
  assertContains ["checking for kern.vty"]  "$( grep kern.vty /boot/loader.conf )" 'kern.vty' 
}

test_dbus_in_rc() {
  assertContains ["dbus"]  "$( grep dbus_enable /etc/rc.conf )" 'YES' 
}

test_proc_in_fstab() {
  assertContains ["/proc"]  "$( grep proc /etc/fstab )" 'proc /proc procfs rw 0 0' 
}

test_group_members() {
  assertContains ["checking video membership"]  "$( grep video /etc/group )" "${testuser}"
  assertContains ["checking video membership"]  "$( grep wheel /etc/group )" "${testuser}"
  assertContains ["checking video membership"]  "$( grep video /etc/group )" 'root' 
}

test_session_files() {
  # X11 desktops use .xinitrc; Wayland compositors seed config + start helper
  if [ -d "${tuhome}/.config/sway" ] || [ -d "${tuhome}/.config/hypr" ] ; then
    assertTrue "wayland start helper exists" "[ -x ${tuhome}/start-desktop.sh ]"
    if [ -d "${tuhome}/.config/sway" ] ; then
      assertTrue "sway config exists" "[ -e ${tuhome}/.config/sway/config ]"
    fi
    if [ -d "${tuhome}/.config/hypr" ] ; then
      assertTrue "hyprland config exists" "[ -e ${tuhome}/.config/hypr/hyprland.conf ]"
    fi
    # seatd should be enabled for Wayland profiles
    assertContains ["seatd enabled"] "$( grep seatd_enable /etc/rc.conf )" 'YES'
  else
    assertTrue "/etc/skel/.xinitrc exists" "[ -e /etc/skel/.xinitrc ]"
    assertTrue "${tuhome}/.xinitrc exists" "[ -e ${tuhome}/.xinitrc ]"
  fi
}

test_pkg_repo_url_configured() {
	# Default is quarterly; latest only if the user opted in. Either is fine.
	_urls=$(grep -rh 'url' /etc/pkg /usr/local/etc/pkg 2>/dev/null || true)
	assertTrue "pkg repo url configured" "[ -n \"${_urls}\" ]"
	assertTrue "pkg repo is quarterly or latest" \
		"echo \"${_urls}\" | grep -Eq 'quarterly|latest'"
}

test_fuse(){
	assertContains ["fuse module in kldlist"] "$(grep kld_list /etc/rc.conf)" fuse
	assertContains ["pkgs contain e2fsprogs"] "$(pkg info)" 'e2fsprogs'
	assertContains ["pkgs contain fusefs"] "$(pkg info)" 'fusefs'
}

test_ipfw_firewall() {
	assertContains ["firewall enabled"] "$(grep firewall_enable /etc/rc.conf)" 'YES'
}

###### shunit2 @ end of file (same directory as this script when installed via the port)
. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/shunit2"
