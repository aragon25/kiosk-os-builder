#!/bin/sh
##############################################
##                                          ##
##  imgldr-install_update                   ##
##                                          ##
##############################################
##############################################
##                                          ##
##    this script should run only from      ##
##            inside initramfs              ##
##                                          ##
##############################################

pretty_text() {
  printf '%s\n%s  %-30s  %s\n' "######################################" "##" "" "##"
  for i in "${@}"; do
    printf "%s  %-30s  %s\n" "##" "$i" "##"
  done
  printf '%s  %-30s  %s\n%s\n' "##" "" "##" "######################################"
}

install_boot() {
  mkdir -p /mnt/sysimg /mnt/oemimg
  if [ -f "/mnt/tmproot/IMAGES/oem.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/oem.img /mnt/oemimg; then
    find /mnt/oemimg/BOOT -maxdepth 1 -mindepth 1 -exec cp -rf {} /mnt/tmpboot/ \;
  elif [ -f "/mnt/tmproot/IMAGES/system.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/system.img /mnt/sysimg; then
    find /mnt/sysimg/BOOT -maxdepth 1 -mindepth 1 -exec cp -rf {} /mnt/tmpboot/ \;
  fi
  sync >/dev/null 2>&1
  umount /mnt/sysimg >/dev/null 2>&1
  umount /mnt/oemimg >/dev/null 2>&1
  return 0
}

install_images() {
  if [ -f "/mnt/tmproot/IMAGES/update/system.img" ]; then
    find /mnt/tmproot/IMAGES -maxdepth 1 -mindepth 1 -not -name 'update' -exec rm -rf {} \;
  else
    find /mnt/tmproot/IMAGES -maxdepth 1 -mindepth 1 -not -name 'update' -not -name 'system.img' -exec rm -rf {} \;
  fi
  find /mnt/tmproot/IMAGES/update -maxdepth 1 -mindepth 1 -type f -not -name 'install_update' -exec mv -f {} /mnt/tmproot/IMAGES/ \;
  rm -rf /mnt/tmproot/SETUP >/dev/null 2>&1
  rm -rf /mnt/tmproot/OEM >/dev/null 2>&1
  rm -rf /mnt/tmproot/OVERLAY/data >/dev/null 2>&1
  return 0
}

collect_and_check_info() {
  local exitcode=0
  mkdir -p /mnt/sysimg /mnt/oemimg
  if [ -f "/mnt/tmproot/IMAGES/update/system.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/update/system.img /mnt/sysimg; then
    if [ -f /mnt/sysimg/INFO/sysinfo ]; then
      cp -f /mnt/sysimg/INFO/sysinfo /usr/share/system_update/sys_sysinfo
    else
      pretty_text "  !!! UPDATE-PACK-ERROR !!!" "    system.img corrupted!" "Does not contain sysinfo file"
      exitcode=1
    fi
  elif [ -f "/mnt/tmproot/IMAGES/update/system.img" ]; then
    pretty_text "  !!! UPDATE-PACK-ERROR !!!" "system.img file not readable!" ""
    exitcode=1
  elif [ -f "/mnt/tmproot/IMAGES/system.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/system.img /mnt/sysimg; then
    if [ -f /mnt/sysimg/INFO/sysinfo ]; then
      cp -f /mnt/sysimg/INFO/sysinfo /usr/share/system_update/sys_sysinfo
    else
      pretty_text "     !!! UPDATE-ERROR !!!" "    system.img corrupted!" "Does not contain sysinfo file"
      exitcode=1
    fi
  else
    pretty_text "     !!! UPDATE-ERROR !!!" "no system.img file is readable" "          or found!"
    exitcode=1
  fi
  if [ -f "/mnt/tmproot/IMAGES/update/oem.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/update/oem.img /mnt/oemimg; then
    if [ -f /mnt/oemimg/INFO/sysinfo ]; then
      cp -f /mnt/oemimg/INFO/sysinfo /usr/share/system_update/oem_sysinfo
    else
      pretty_text "  !!! UPDATE-PACK-ERROR !!!" "      oem.img corrupted!" "Does not contain sysinfo file"
      exitcode=1
    fi
  elif [ -f "/mnt/tmproot/IMAGES/update/oem.img" ]; then
    pretty_text "  !!! UPDATE-PACK-ERROR !!!" "  oem.img file not readable!" ""
    exitcode=1
  else
    cp -f /usr/share/system_update/sys_sysinfo /usr/share/system_update/oem_sysinfo
  fi
  if [ "$(cat /usr/share/system_update/sys_sysinfo 2>/dev/null)" != "$(cat /usr/share/system_update/oem_sysinfo 2>/dev/null)" ]; then
    pretty_text "  !!! UPDATE-PACK-ERROR !!!" "    system.img and oem.img" "        do not match!"
    exitcode=1
  fi
  sync >/dev/null 2>&1
  umount /mnt/sysimg >/dev/null 2>&1
  umount /mnt/oemimg >/dev/null 2>&1
  return $exitcode
}

if [ "$(readlink -f "$0")" = "/usr/share/system_update/install_update" ]; then
  if collect_and_check_info; then
    install_images
    install_boot
  else
    exit 1
  fi
else
  echo "##############################################"
  echo "##                                          ##"
  echo "##    this script should run only from      ##"
  echo "##            inside initramfs              ##"
  echo "##                                          ##"
  echo "##############################################"
fi
exit 0
