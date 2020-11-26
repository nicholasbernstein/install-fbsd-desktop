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
      echo $desktop
      DESKTOP_PGKS="kde5 sddm" 
      sysrc sddm_enable="YES"
      ;;
  LXQT)
      echo $desktop
      DESKTOP_PGKS="lxqt sddm" 
      sysrc sddm_enable="YES"
      ;;
  Gnome3)
      echo $desktop
      DESKTOP_PGKS="gnome3" 
      sysrc gnome_enable="YES"
      sysrc gdm_enable="YES"
      ;;

  xfce4)
      echo $desktop
      DESKTOP_PGKS="xfce sddm" 
      sysrc sddm_enable="YES"
      ;;
  mate)
      echo $desktop
      DESKTOP_PGKS="mate sddm" 
      sysrc sddm_enable="YES"
      ;;
  *)
     echo $desktop 
     read foo ;;
  esac

echo "install command: pkg install xorg $DESKTOP_PGKS" 
pkg install xorg $DESKTOP_PGKS 

sysrc dbus_enable="YES"
sysrc hald_enable="YES"

grep "proc /proc procfs" /etc/fstab || echo "proc /proc procfs rw 0 0" >> /etc/fstab
#!/bin/sh


