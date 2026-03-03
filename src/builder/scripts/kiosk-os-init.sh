#!/bin/sh
##############################################
##                                          ##
##  imgldr-init                             ##
##                                          ##
##############################################
##############################################
##                                          ##
##    this script should run only once      ##
##      after flashing image to disk        ##
##                                          ##
##############################################

mount_basefs () {
  if grep -q ' /mnt/rootfs ' /etc/fstab >/dev/null 2>&1; then 
    ROOT_DIR="/mnt/rootfs"
  elif grep -q ' / ' /etc/fstab >/dev/null 2>&1; then 
    ROOT_DIR=""
  else
    FAIL_REASON="No root_partition found in /etc/fstab..."
    return 1
  fi
  if grep -q ' /boot/firmware ' /etc/fstab >/dev/null 2>&1; then 
    BOOT_DIR="/boot/firmware"
  elif grep -q ' /boot ' /etc/fstab >/dev/null 2>&1; then 
    BOOT_DIR="/boot"
  else
    FAIL_REASON="No boot_partition found in /etc/fstab..."
    return 1
  fi
  [ -z $ROOT_DIR ] && local ROOT_DIR="/"
  mount $ROOT_DIR >/dev/null 2>&1
  mount $ROOT_DIR -o remount,ro
  mount $BOOT_DIR >/dev/null 2>&1
  mount $BOOT_DIR -o remount,ro
  return 0
}

check_commands () {
  if ! command -v whiptail > /dev/null; then
      echo "whiptail not found"
      sleep 5
      return 1
  fi
  for COMMAND in grep cut sed parted fdisk findmnt; do
    if ! command -v $COMMAND > /dev/null; then
      FAIL_REASON="$COMMAND not found"
      return 1
    fi
  done
  return 0
}

get_variables () {
  [ -z $ROOT_DIR ] && local ROOT_DIR="/"
  ROOT_PART_DEV=$(findmnt $ROOT_DIR -o source -n)
  ROOT_PART_NAME=$(echo "$ROOT_PART_DEV" | cut -d "/" -f 3)
  ROOT_DEV_NAME=$(echo /sys/block/*/"${ROOT_PART_NAME}" | cut -d "/" -f 4)
  ROOT_DEV="/dev/${ROOT_DEV_NAME}"
  ROOT_PART_NUM=$(cat "/sys/block/${ROOT_DEV_NAME}/${ROOT_PART_NAME}/partition")
  BOOT_PART_DEV=$(findmnt $BOOT_DIR -o source -n)
  BOOT_PART_NAME=$(echo "$BOOT_PART_DEV" | cut -d "/" -f 3)
  BOOT_DEV_NAME=$(echo /sys/block/*/"${BOOT_PART_NAME}" | cut -d "/" -f 4)
  BOOT_DEV="/dev/${BOOT_DEV_NAME}"
  BOOT_PART_NUM=$(cat "/sys/block/${BOOT_DEV_NAME}/${BOOT_PART_NAME}/partition")
  OLD_DISKID=$(fdisk -l "$ROOT_DEV" | sed -n 's/Disk identifier: 0x\([^ ]*\)/\1/p')
  ROOT_DEV_SIZE=$(cat "/sys/block/${ROOT_DEV_NAME}/size")
  TARGET_END=$((ROOT_DEV_SIZE - 1))
  PARTITION_TABLE=$(parted -m "$ROOT_DEV" unit s print | tr -d 's')
  LAST_PART_NUM=$(echo "$PARTITION_TABLE" | tail -n 1 | cut -d ":" -f 1)
  ROOT_PART_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${ROOT_PART_NUM}:")
  ROOT_PART_START=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 2)
  ROOT_PART_END=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 3)
  if [ ! -b "$ROOT_DEV" ]; then 
    FAIL_REASON="Could not get root device!"
    return 1
  fi
  if [ ! -b "$ROOT_PART_DEV" ]; then 
    FAIL_REASON="Could not get root partition!"
    return 1
  fi
  if [ ! -b "$BOOT_PART_DEV" ]; then 
    FAIL_REASON="Could not get boot partition!"
    return 1
  fi
  return 0
}

fix_partuuid() {
  whiptail --infobox "Fix PARTUUID..." 20 60
  sleep 2
  mount -o remount,rw "$ROOT_PART_DEV"
  mount -o remount,rw "$BOOT_PART_DEV"
  DISKID="$(tr -dc 'a-f0-9' < /dev/hwrng | dd bs=1 count=8 2>/dev/null)"
  fdisk "$ROOT_DEV" >/dev/null 2>&1 <<EOF
x
i
0x$DISKID
r
w
EOF
  if [ "$?" -eq 0 ]; then
    sed -i "s/${OLD_DISKID}/${DISKID}/" $BOOT_DIR/cmdline.txt
  fi
  sync
  mount -o remount,ro "$ROOT_PART_DEV"
  mount -o remount,ro "$BOOT_PART_DEV"
}

convert_imager_settings() {
  if [ -e $BOOT_DIR/firstrun.sh ]; then
    whiptail --infobox "Import Imager settings..." 20 60
    sleep 2
    mount -o remount,rw "$ROOT_PART_DEV"
    mount -o remount,rw "$BOOT_PART_DEV"
    mkdir -p "$ROOT_DIR/CONFIG" >/dev/null 2>&1
    if grep -q 'imager_custom set_wlan' $BOOT_DIR/firstrun.sh; then
      wifi_hidden="false"
      wifi_ssid=$(awk '{for(i=1;i<=NF;i++)if($i~/set_wlan/)print $(i+1)}' $BOOT_DIR/firstrun.sh)
      [ "$wifi_ssid" = "-h" ] && wifi_hidden="true" && wifi_ssid=$(awk '{for(i=1;i<=NF;i++)if($i~/'$wifi_ssid'/)print $(i+1)}' $BOOT_DIR/firstrun.sh)
      wifi_ssid=$(echo $wifi_ssid | sed "s/['\"]//g")
      wifi_key=$(awk '{for(i=1;i<=NF;i++)if($i~/'$wifi_ssid'/)print $(i+1)}' $BOOT_DIR/firstrun.sh)
      wifi_key=$(echo $wifi_key | sed "s/['\"]//g")
      wifi_country=$(awk '{for(i=1;i<=NF;i++)if($i~/'$wifi_key'/)print $(i+1)}' $BOOT_DIR/firstrun.sh)
      wifi_country=$(echo $wifi_country | sed "s/['\"]//g")
      if [ -n "$wifi_country" ]; then
        sed -i 's|cfg80211\.ieee80211_regdom=[^ ]* \{0,1\}||g' $BOOT_DIR/cmdline.txt
        sed -i 's|[ \t]*$||' $BOOT_DIR/cmdline.txt
        sed -i "s/$/ cfg80211.ieee80211_regdom=$wifi_country/g" $BOOT_DIR/cmdline.txt
        echo "$wifi_country" > "$ROOT_DIR/CONFIG/wifi_country"
      fi
      echo "interface=wlan0" > "$ROOT_DIR/CONFIG/wifi_network_wlan0_imgldr"
      echo "powersafe=false" >> "$ROOT_DIR/CONFIG/wifi_network_wlan0_imgldr"
      echo "ssid=$wifi_ssid" >> "$ROOT_DIR/CONFIG/wifi_network_wlan0_imgldr"
      echo "key=$wifi_key" >> "$ROOT_DIR/CONFIG/wifi_network_wlan0_imgldr"
      echo "hidden=$wifi_hidden" >> "$ROOT_DIR/CONFIG/wifi_network_wlan0_imgldr"
    fi
    if grep -q 'imager_custom set_hostname' $BOOT_DIR/firstrun.sh; then
      awk '{for(i=1;i<=NF;i++)if($i~/set_hostname/)print $(i+1)}' $BOOT_DIR/firstrun.sh > "$ROOT_DIR/CONFIG/hostname"
      sed -i "s/['\"]//g" "$ROOT_DIR/CONFIG/hostname"
    fi
    if grep -q '/usr/lib/userconf-pi/userconf' $BOOT_DIR/firstrun.sh; then
      sysuser_name=$(awk '{for(i=1;i<=NF;i++)if($i~/\/usr\/lib\/userconf-pi\/userconf/)print $(i+1)}' $BOOT_DIR/firstrun.sh | sed '1d' | sed "s/['\"]//g" | awk 'NR==1 {print $1}' 2>/dev/null)
      sysuser_pwd=$(awk '{for(i=1;i<=NF;i++)if($i~/\/usr\/lib\/userconf-pi\/userconf/)print $(i+2)}' $BOOT_DIR/firstrun.sh | sed '1d' | sed "s/['\"]//g" | awk 'NR==1 {print $1}' 2>/dev/null)
      [ "$sysuser_name" = "" ] && sysuser_name="admin"
      [ "$sysuser_pwd" = "" ] && sysuser_pwd='$1$25pgtsyy$hoEN68XR9byPK/RdSElWa/'
      echo "username=$sysuser_name" > "$ROOT_DIR/CONFIG/admin_conf"
      echo "password=$sysuser_pwd" >> "$ROOT_DIR/CONFIG/admin_conf"
    fi
    if grep -q 'imager_custom set_keymap' $BOOT_DIR/firstrun.sh; then
      awk '{for(i=1;i<=NF;i++)if($i~/set_keymap/)print $(i+1)}' $BOOT_DIR/firstrun.sh > "$ROOT_DIR/CONFIG/keymap"
      sed -i "s/['\"]//g" "$ROOT_DIR/CONFIG/keymap"
    fi
    if grep -q 'imager_custom set_timezone' $BOOT_DIR/firstrun.sh; then
      awk '{for(i=1;i<=NF;i++)if($i~/set_timezone/)print $(i+1)}' $BOOT_DIR/firstrun.sh > "$ROOT_DIR/CONFIG/timezone"
      sed -i "s/['\"]//g" "$ROOT_DIR/CONFIG/timezone"
    fi
    if grep -q 'imager_custom enable_ssh' $BOOT_DIR/firstrun.sh; then
      echo "real_vnc=true" > "$ROOT_DIR/CONFIG/remote_conf"
      echo "vnc_web=true" >> "$ROOT_DIR/CONFIG/remote_conf"
      echo "cockpit=true" >> "$ROOT_DIR/CONFIG/remote_conf"
      echo "ssh=true" >> "$ROOT_DIR/CONFIG/remote_conf"
    else
      echo "real_vnc=false" > "$ROOT_DIR/CONFIG/remote_conf"
      echo "vnc_web=false" >> "$ROOT_DIR/CONFIG/remote_conf"
      echo "cockpit=false" >> "$ROOT_DIR/CONFIG/remote_conf"
      echo "ssh=false" >> "$ROOT_DIR/CONFIG/remote_conf"
    fi
    rm -f $BOOT_DIR/firstrun.sh
    sync
    mount -o remount,ro "$ROOT_PART_DEV"
    mount -o remount,ro "$BOOT_PART_DEV"
  fi
}

create_ssh_keys () {
  whiptail --infobox "Generating SSH keys..." 20 60
  sleep 2
  mount -o remount,rw "$ROOT_PART_DEV"
  rm -f /etc/ssh/*_key* >/dev/null 2>&1
  ssh-keygen -A >/dev/null 2>&1
  mkdir -p "$ROOT_DIR/STATIC/ssh_keys" >/dev/null 2>&1
  rm -f $ROOT_DIR/STATIC/ssh_keys/*_key* >/dev/null 2>&1
  cp -f /etc/ssh/*_key* "$ROOT_DIR/STATIC/ssh_keys/" >/dev/null 2>&1
  sync
  mount -o remount,ro "$ROOT_PART_DEV"
}

create_machine_id () {
  whiptail --infobox "Generating machine-id..." 20 60
  sleep 2
  mount -o remount,rw "$ROOT_PART_DEV"
  rm -f /etc/machine-id >/dev/null 2>&1
  rm -f /var/lib/dbus/machine-id >/dev/null 2>&1
  systemd-machine-id-setup >/dev/null 2>&1
  ln -s /etc/machine-id /var/lib/dbus/machine-id >/dev/null 2>&1
  mkdir -p "$ROOT_DIR/STATIC" >/dev/null 2>&1
  cp -f /etc/machine-id "$ROOT_DIR/STATIC/machine-id" >/dev/null 2>&1
  sync
  mount -o remount,ro "$ROOT_PART_DEV"
}

create_ssl_cert () {
  whiptail --infobox "Generating ssl-cert..." 20 60
  sleep 2
  mount -o remount,rw "$ROOT_PART_DEV"
  mkdir -p "$ROOT_DIR/STATIC" >/dev/null 2>&1
  rm -f "$ROOT_DIR/STATIC/ssl_selfsigned.cert" >/dev/null 2>&1
  rm -f "$ROOT_DIR/STATIC/ssl_selfsigned.key" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:4096 -out "$ROOT_DIR/STATIC/ssl_selfsigned.cert" -keyout "$ROOT_DIR/STATIC/ssl_selfsigned.key" -sha256 -days 3650 -nodes -subj "/" >/dev/null 2>&1
  sync
  mount -o remount,ro "$ROOT_PART_DEV"
}

do_resize () {
  [ "$BOOT_DEV_NAME" != "$ROOT_DEV_NAME" ] && return 1
  [ $ROOT_PART_NUM -ne $LAST_PART_NUM ] && return 1
  [ $ROOT_PART_END -ge $TARGET_END ] && return 1
  whiptail --infobox "Resizing root filesystem...\n\nDepending on storage size and speed, this may take a while." 20 60
  sleep 2
  if ! printf "yes\n%ss\n" "$TARGET_END" | parted -m "$ROOT_DEV" u s resizepart "$ROOT_PART_NUM" ---pretend-input-tty >/dev/null 2>&1; then
    return 1
  fi
  mount -o remount,rw "$ROOT_PART_DEV"
  resize2fs "$ROOT_PART_DEV" >/dev/null 2>&1
  mount -o remount,ro "$ROOT_PART_DEV"
}

export LC_ALL=C
export LANG=C
mount -t proc proc /proc >/dev/null 2>&1
mount -t sysfs sys /sys >/dev/null 2>&1
mount -t tmpfs tmp /run >/dev/null 2>&1
mkdir -p /run/systemd >/dev/null 2>&1

if check_commands && mount_basefs && get_variables; then
  mount -o remount,rw "$BOOT_PART_DEV"
  sed -i 's|init=[^ ]* \{0,1\}||g' $BOOT_DIR/cmdline.txt
  sed -i 's|FIRSTBOOT[^ ]* \{0,1\}||g' $BOOT_DIR/cmdline.txt
  sed -i 's|systemd\.[^ ]* \{0,1\}||g' $BOOT_DIR/cmdline.txt
  sed -i 's|sdhci\.debug_quirks2=4[^ ]* \{0,1\}||g' $BOOT_DIR/cmdline.txt
  sed -i 's|[ \t]*$||' $BOOT_DIR/cmdline.txt
  sync
  mount -o remount,ro "$BOOT_PART_DEV"
  do_resize
  fix_partuuid
  convert_imager_settings
  create_ssh_keys
  create_machine_id
  create_ssl_cert
  whiptail --infobox "Rebooting in 5 seconds..." 20 60
elif command -v whiptail >/dev/null; then
  whiptail --infobox "Firstboot failed:\n$FAIL_REASON\n\nRebooting in 5 seconds..." 20 60
else
  echo -e "Firstboot failed:\n$FAIL_REASON\n\nRebooting in 5 seconds..."
  echo "Rebooting in 5 seconds..."
fi

sync
[ -n $BOOT_PART_DEV ] && umount $BOOT_PART_DEV >/dev/null 2>&1
[ -n $ROOT_PART_DEV ] && umount $ROOT_PART_DEV >/dev/null 2>&1
sleep 5
vcgencmd display_power 0 >/dev/null 2>&1
reboot -f
sleep 5
exit 0
