#!/bin/bash
default_user=`grep 1001 /etc/passwd | awk -F: '{ print $1 }'`
VUSER=`dialog --title "Video User" --clear \
        --inputbox "What user should be added to the video group?" 0 0  $default_user --stdout`


pw groupmod video -m $VUSER 

desktop=`dialog --clear --title "Select Desktop" \
        --menu "Select desktop environment to be installed" 0 0 0 \
        "KDE"  "KDE Destkop Environment" \
        "LXQT" "Lightweight Desktop based on QT" \
        "Gnome3" "The modern Gnome Desktop" \
        "xfce4" "Lightweight XFCE desktop" \
        "mate"  "Mate dekstop based on gtk" --stdout`

case $desktop in
  KDE)
      DESKTOP_PGKS="kde5 sddm" 
      sysrc sddm_enable="YES"
      ;;
  LXQT)
      DESKTOP_PGKS="lxqt sddm" 
      sysrc sddm_enable="YES"
      ;;
  Gnome3)
      DESKTOP_PGKS="gnome3" 
      sysrc gnome_enable="YES"
      sysrc gdm_enable="YES"
      ;;

  xfce4)
      DESKTOP_PGKS="xfce sddm" 
      sysrc sddm_enable="YES"
      ;;
  mate)
      DESKTOP_PGKS="mate sddm" 
      sysrc sddm_enable="YES"
      ;;

  esac

pkg install xorg sddm $DESKTOP_PKGS

sysrc dbus_enable="YES"
sysrc hald_enable="YES"

grep "proc /proc procfs" /etc/fstab || echo "proc /proc procfs rw 0 0" >> /etc/fstab
#!/bin/sh


