#!/usr/bin/sudo bash
##############################################
##                                          ##
##  build_images.sh                         ##
##                                          ##
##############################################

#get some variables
export LC_ALL=C
export LANG=C
SCRIPT_TITLE="kiosk-os-builder"
SCRIPT_VERSION="1.4"
SCRIPTDIR="$(readlink -f "$0")"
SCRIPTNAME="$(basename "$SCRIPTDIR")"
SCRIPTBASENAME="$(basename "$SCRIPTDIR" ".sh")"
SCRIPTDIR="$(dirname "$SCRIPTDIR")"
OUTPUTDIR="$SCRIPTDIR/build"
RELEASEDIR="$SCRIPTDIR/release"
CONFIGFILE="$SCRIPTDIR/$SCRIPTBASENAME.conf"
USERID="${SUDO_UID:-$UID}"
GROUPID="$(id -g $USERID)"
LOGFILE="$OUTPUTDIR/build.log"
TARGET_SYS="mount_rootfs"
IMAGE_LOAD="base_root"
EXITCODE=0

#check commands
for i in "$@"
do
  case $i in
    -b=*)
    BASE_BOOT=${i#-b=}
    shift # past argument
    ;;
    -r=*)
    BASE_ROOT=${i#-r=}
    shift # past argument
    ;;
    -C=*)
    T_CONFIGFILE=${i#-C=}
    CONFIGFILE="$SCRIPTDIR/$T_CONFIGFILE"
    shift # past argument
    ;;
    -D=*)
    DEVICE=${i#-D=}
    shift # past argument
    ;;
    -V=*)
    VERSION=${i#-V=}
    shift # past argument
    ;;
    -B=*)
    BRANCH=${i#-B=}
    shift # past argument
    ;;
    -S=*)
    SERVER=${i#-S=}
    shift # past argument
    ;;
    -v|--version)
    [ "$CMD" == "" ] && CMD="version" || CMD="help"
    shift # past argument
    ;;
    -h|--help)
    CMD="help"
    shift # past argument
    ;;
    *)
    if [ "$i" != "" ]
    then
      echo "Unknown option: $i"
      exit 1
    fi
    ;;
  esac
done
[ "$CMD" == "" ] && CMD="MENU"
FAIL_REASON=""

function format_image_load_images() {
  case "${IMAGE_LOAD}" in
    base_root) echo "." ;;
    *) echo "${IMAGE_LOAD}" ;;
  esac
}

function format_image_load_data() {
  case "${IMAGE_LOAD}" in
    base_root) echo "BASE_IMAGE" ;;
    *) echo "${IMAGE_LOAD}" ;;
  esac
}

function set_base_perms() {
  local filetype
  local entry
  local test
  IFS=$'\n'
  test=($(find "$1"))
  if [ "${#test[@]}" != "0" ]; then
    for entry in ${test[@]}; do
      chown -f $USERID:$GROUPID "$entry"
      if [ -f "$entry" ]; then
        filetype=$(file -b --mime-type "$entry" 2>/dev/null)
        if [[ "$filetype" =~ "executable" ]] || [[ "$filetype" =~ "script" ]] || 
           [[ "$entry" == *".desktop" ]] || [[ "$entry" == *".sh" ]]|| [[ "$entry" == *".py" ]]; then
          chmod -f 775 "$entry"
        else
          chmod -f 664 "$entry"
        fi
      elif [ -d "$entry" ]; then
        chmod -f 775 "$entry"
      fi
    done
  fi
  unset IFS
}

function config_read(){ # path, key, defaultvalue -> value
  local val=$( (grep -E "^${2}=" -m 1 "${1}" 2>/dev/null || echo "VAR=__UNDEFINED__") | head -n 1 | cut -d '=' -f 2-)
  #val=$(echo "${val}" | sed 's/ *$//g' | sed 's/^ *//g')
  val=$(echo "$val" | xargs)
  [ "${val}" == "__UNDEFINED__" ] || [ "${val}" == "" ] && val="$3"
  printf -- "%s" "${val}"
}

function config_read_all(){
  if [ "$CONFIGFILE" != "$SCRIPTDIR/$SCRIPTBASENAME.conf" ] && [ ! -f "$CONFIGFILE" ]; then
    msgbox "Error! Configfile:\n$CONFIGFILE\nnot found!"
    exit 1
  fi
  [ -z "$DEVICE" ] && DEVICE=$(config_read "$CONFIGFILE" DEVICE "")
  [ -z "$VERSION" ] && VERSION=$(config_read "$CONFIGFILE" VERSION "")
  [ -z "$BRANCH" ] && BRANCH=$(config_read "$CONFIGFILE" BRANCH "")
  [ -z "$SERVER" ] && SERVER=$(config_read "$CONFIGFILE" SERVER "")
  [ -z "$BASE_BOOT" ] && BASE_BOOT=$(config_read "$CONFIGFILE" BASE_BOOT "base/bootfs")
  BASE_BOOT=$(echo "$BASE_BOOT" | sed "s#^/\(.*\)#\1#" | sed "s#\(.*\)/\$#\1#")
  [ -z "$BASE_ROOT" ] && BASE_ROOT=$(config_read "$CONFIGFILE" BASE_ROOT "base/rootfs")
  BASE_ROOT=$(echo "$BASE_ROOT" | sed "s#^/\(.*\)#\1#" | sed "s#\(.*\)/\$#\1#")
}

function compare_version(){ # installed_version, check_version -> 0 = installed_version is newer or same 1 = installed_version is older
  IFS=.
  local ver1=($1)
  local ver2=($2)
  local retcode=0
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
  do
    ver1[i]=0
  done
  for ((i=0; i<${#ver1[@]}; i++))
  do
    if [[ -z ${ver2[i]} ]]
    then
        ver2[i]=0
    fi
    if ((10#${ver1[i]} < 10#${ver2[i]}))
    then
      retcode=1
    fi
  done
  unset IFS
  return $retcode
}

function cool_down () {
  sync >/dev/null 2>&1
  sleep 2
  return 0
}

function write_perms () {
  local exitcode=0
  touch "$OUTPUTDIR/mount_bootfs/test.dummy" >/dev/null 2>&1 || exitcode=1
  touch "$OUTPUTDIR/mount_rootfs/test.dummy" >/dev/null 2>&1 || exitcode=1
  rm -f "$OUTPUTDIR/mount_bootfs/test.dummy" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/mount_rootfs/test.dummy" >/dev/null 2>&1
  return $exitcode
}

function umount_devices () {
  cool_down
  umount $BOOT_DEV >/dev/null 2>&1
  umount $ROOT_DEV >/dev/null 2>&1
  sleep 2
  return 0
}

function mount_devices () {
  local exitcode=0
  umount_devices
  mount -w $BOOT_DEV "$OUTPUTDIR/mount_bootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && exitcode=1
  mount -w $ROOT_DEV "$OUTPUTDIR/mount_rootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && exitcode=1
  sleep 2
  write_perms || exitcode=1
  [ $exitcode -ne 0 ] && umount_devices
  return $exitcode
}

function expand_device () { #partition endblock
  umount_devices >/dev/null 2>&1
  printf "%sB\n" "$2" | parted -m "$MAIN_DEV" u b resizepart "$1" ---pretend-input-tty >/dev/null 2>&1
  cool_down
  e2fsck -f -y ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  resize2fs -f ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  e2fsck -f -y ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  return 0
}

function shrink_device () { #partition startblock
  umount_devices >/dev/null 2>&1
  e2fsck -f -y ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  resize2fs -f -M ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  e2fsck -f -y ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  local filesystem_info=$(tune2fs -l ${MAIN_DEV}${1})
  local block_count=$(echo "$filesystem_info" | grep -e "^Block count:" | cut -d ":" -f 2 | sed 's/^ *//g')
  local block_size=$(echo "$filesystem_info" | grep -e "^Block size:" | cut -d ":" -f 2 | sed 's/^ *//g')
  local sys_min_end=$((block_count * block_size))
  sys_min_end=$((sys_min_end + $2 - 1))
  printf "%sB\nyes\n" "$sys_min_end" | parted -m "$MAIN_DEV" u b resizepart "$1" ---pretend-input-tty >/dev/null 2>&1
  cool_down
  e2fsck -f -y ${MAIN_DEV}${1} >/dev/null 2>&1
  cool_down
  return 0
}

function check_superuser () {
  if [ $UID -ne 0 ]; then
    FAIL_REASON="not superuser"
    EXITCODE=1
    return 1
  fi
  return 0
}

function check_commands () {
  local cmd=""
  for cmd in grep cut sed parted fdisk findmnt resize2fs e2fsck tune2fs zip md5sum sha512sum whiptail; do
    if ! command -v $cmd >/dev/null; then
      FAIL_REASON="$cmd not found"
      EXITCODE=1
      return 1
    fi
  done
  return 0
}

function check_getvar_dev () {
  MAIN_DEV="/dev/$DEVICE"
  local MAIN_NAME=$(echo "$MAIN_DEV" | cut -d "/" -f 3)
  ROOT_NUM="2"
  BOOT_NUM="1"
  ROOT_DEV="${MAIN_DEV}${ROOT_NUM}"
  BOOT_DEV="${MAIN_DEV}${BOOT_NUM}"
  local ROOT_NAME=$(echo "$ROOT_DEV" | cut -d "/" -f 3)
  local BOOT_NAME=$(echo "$BOOT_DEV" | cut -d "/" -f 3)
  if ! parted -ms "$MAIN_DEV" print >/dev/null 2>&1; then
    FAIL_REASON="$MAIN_DEV not found"
    EXITCODE=1
    return 1
  fi
  if [ "$(blkid -o value -s LABEL $BOOT_DEV)" != "bootfs" ]; then
    FAIL_REASON="$BOOT_DEV label not match 'bootfs'"
    EXITCODE=1
    return 1
  fi
  if [ "$(blkid -o value -s LABEL $ROOT_DEV)" != "rootfs" ]; then
    FAIL_REASON="$ROOT_DEV label not match 'rootfs'"
    EXITCODE=1
    return 1
  fi
  fsck -a $BOOT_DEV >/dev/null 2>&1
  fsck -a $ROOT_DEV >/dev/null 2>&1
  e2fsck -f -y $ROOT_DEV >/dev/null 2>&1
  local PARTITION_TABLE=$(parted -m "$MAIN_DEV" unit b print | tr -d 'B')
  local LAST_PART_NUM=$(echo "$PARTITION_TABLE" | tail -n 1 | cut -d ":" -f 1)
  local MAIN_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${MAIN_DEV}:")
  local ROOT_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${ROOT_NUM}:")
  local BOOT_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${BOOT_NUM}:")
  ROOT_START=$(echo "$ROOT_LINE" | cut -d ":" -f 2)
  BOOT_START=$(echo "$BOOT_LINE" | cut -d ":" -f 2)
  ROOT_END=$(echo "$ROOT_LINE" | cut -d ":" -f 3)
  BOOT_END=$(echo "$BOOT_LINE" | cut -d ":" -f 3)
  local MAIN_SIZE=$(echo "$MAIN_LINE" | cut -d ":" -f 2)
  MAIN_END=$((MAIN_SIZE - 1))
  DISKID=$(fdisk -l "$MAIN_DEV" | sed -n 's/Disk identifier: 0x\([^ ]*\)/\1/p')
  if [ $ROOT_NUM -ne $LAST_PART_NUM ] ; then
    FAIL_REASON="$ROOT_DEV is not last partition!"
    EXITCODE=1
    return 1
  fi
  return 0
}

function create_folders () {
  umount_devices
  rm -rf "$OUTPUTDIR"
  mkdir -p "$OUTPUTDIR/mount_bootfs"
  mkdir -p "$OUTPUTDIR/mount_rootfs"
  mkdir -p "$OUTPUTDIR/mount_sqfs"
  mkdir -p "$OUTPUTDIR/mount_devel"
  mkdir -p "$OUTPUTDIR/images"
  mkdir -p "$RELEASEDIR"
  [ -f "$LOGFILE" ] && rm -f "$LOGFILE"
  printf "Log File - " >> "$LOGFILE" && date >> "$LOGFILE"
  set_base_perms "$OUTPUTDIR"
  set_base_perms "$RELEASEDIR"
  return 0
}

function cleanup_rootfs () {
  ! ls "$OUTPUTDIR/mount_rootfs/"* >/dev/null 2>&1 && return 1
  rm -rf "$OUTPUTDIR/mount_rootfs/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_rootfs/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_rootfs/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_rootfs/lost+found/"* >/dev/null 2>&1
  return 0
}

function cleanup_target_system () {
  ! ls "$OUTPUTDIR/$TARGET_SYS/"* >/dev/null 2>&1 && return 1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/lost+found/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/tmp/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/var/tmp/"* >/dev/null 2>&1
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/etc/machine-id" >/dev/null 2>&1
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/var/lib/dbus/machine-id" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/ssh/ssh_host_"*"_key"* >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/var/lib/dhcp/"* >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/network/interfaces.d/"* >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/wpa_supplicant/wpa_supplicant"*".conf" >/dev/null 2>&1
  echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev" > "$OUTPUTDIR/$TARGET_SYS/etc/wpa_supplicant/wpa_supplicant.conf"
  echo "update_config=1" >> "$OUTPUTDIR/$TARGET_SYS/etc/wpa_supplicant/wpa_supplicant.conf"
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/NetworkManager/system-connections/sqfs_"*".nmconnection" >/dev/null 2>&1
  [ -f "$OUTPUTDIR/$TARGET_SYS/etc/dhcpcd.conf" ] && sed -i '/#___IMGLDR_CONFIG_BEGIN___/,/#___IMGLDR_CONFIG_END___/d' "$OUTPUTDIR/$TARGET_SYS/etc/dhcpcd.conf" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/vnc-web/vncpasswd.pass" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/timezone" >/dev/null 2>&1
  echo "UTC" > "$OUTPUTDIR/$TARGET_SYS/etc/timezone"
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/localtime" >/dev/null 2>&1
  ln -s /usr/share/zoneinfo/UTC "$OUTPUTDIR/$TARGET_SYS/etc/localtime"
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/console-setup/cached_"* >/dev/null 2>&1
  cat >"$OUTPUTDIR/$TARGET_SYS/etc/default/keyboard" <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"

EOF
  rm -f "$OUTPUTDIR/$TARGET_SYS/root/.bash_history" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/root/.vnc" >/dev/null 2>&1
  local first_userid=$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $3; exit }' "$OUTPUTDIR/$TARGET_SYS/etc/passwd" 2>/dev/null)
  local first_username=$(awk -F: -v uid="$first_userid" '$3 == uid { print $1; exit }' "$OUTPUTDIR/$TARGET_SYS/etc/passwd" 2>/dev/null)
  local first_usergid=$(awk -F: -v uid="$first_userid" '$3 == uid { print $4; exit }' "$OUTPUTDIR/$TARGET_SYS/etc/passwd" 2>/dev/null)
  local first_usergname=$(awk -F: -v gid="$first_usergid" '$3 == gid { print $1; exit }' "$OUTPUTDIR/$TARGET_SYS/etc/group" 2>/dev/null)
  local first_userhome=$(awk -F: -v uid="$first_userid" '$3 == uid { print $6; exit }' "$OUTPUTDIR/$TARGET_SYS/etc/passwd" 2>/dev/null)
  if [ -n "$first_username" ]; then
    rm -rf "$OUTPUTDIR/$TARGET_SYS$first_userhome" >/dev/null 2>&1
    cp -rf "$OUTPUTDIR/$TARGET_SYS/etc/skel"/. "$OUTPUTDIR/$TARGET_SYS$first_userhome" >/dev/null 2>&1
    chown -R ${first_userid}:${first_usergid} "$OUTPUTDIR/$TARGET_SYS$first_userhome" >/dev/null 2>&1
  fi
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/cockpit/ws-certs.d/"* >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/nginx/sites-enabled/vnc-web" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/$TARGET_SYS/etc/vnc-web/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/$TARGET_SYS/var/log/journal/"* >/dev/null 2>&1
  find "$OUTPUTDIR/$TARGET_SYS/var/log/" -type f -name "*.log" -exec truncate -s 0 {} + >/dev/null 2>&1
  find "$OUTPUTDIR/$TARGET_SYS/var/log/" -type f -name "*.[0-9]" -delete >/dev/null 2>&1
  find "$OUTPUTDIR/$TARGET_SYS/var/log/" -type f -name "*.gz" -delete >/dev/null 2>&1
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/var/log/dmesg" 2>/dev/null
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/var/log/wtmp" 2>/dev/null
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/var/log/lastlog" 2>/dev/null
  truncate -s 0 "$OUTPUTDIR/$TARGET_SYS/var/log/btmp" 2>/dev/null
  rm -rf "$OUTPUTDIR/$TARGET_SYS/var/cache/apt/archives/"* 2>/dev/null
  rm -rf "$OUTPUTDIR/$TARGET_SYS/var/lib/apt/lists/"* 2>/dev/null
  #sed -i "s/127\.0\.1\.1.*$(<"$OUTPUTDIR/$TARGET_SYS/etc/hostname")/127.0.1.1\traspi/g" "$OUTPUTDIR/$TARGET_SYS/etc/hosts"
  sed -i "s/^127.0.1.1.*/127.0.1.1\traspi/" "$OUTPUTDIR/$TARGET_SYS/etc/hosts"
  echo "raspi" > "$OUTPUTDIR/$TARGET_SYS/etc/hostname"
  if -f "$OUTPUTDIR/$TARGET_SYS/etc/default/crda" 2>/dev/null; then
      sed -i "s/^REGDOMAIN=.*$/REGDOMAIN=/" "$OUTPUTDIR/$TARGET_SYS/etc/default/crda" >/dev/null 2>&1
  fi
  if grep -q "WirelessEnabled=true" "$OUTPUTDIR/$TARGET_SYS/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null; then
    sed -i 's/^WirelessEnabled=.*/WirelessEnabled=false/' "$OUTPUTDIR/$TARGET_SYS/var/lib/NetworkManager/NetworkManager.state" >/dev/null 2>&1
  fi
  local filename
  for filename in "$OUTPUTDIR/$TARGET_SYS/var/lib/systemd/rfkill/"*:wlan ; do
    echo 1 > "$filename"
  done
  return 0
}

function gen_boot_folder () {
  ! cleanup_rootfs && return 1
  ! ls "$OUTPUTDIR/mount_bootfs/"* >/dev/null 2>&1 && return 1
  rm -rf "$OUTPUTDIR/mount_rootfs/BOOT" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_bootfs/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_bootfs/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_bootfs/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_bootfs/lost+found/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_bootfs/."* >/dev/null 2>&1 
  rm -rf "$OUTPUTDIR/mount_bootfs/FSCK"*".REC" >/dev/null 2>&1
  mkdir -p "$OUTPUTDIR/mount_rootfs/BOOT"
  cp -f "$OUTPUTDIR/mount_bootfs/initramfs"* "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/kernel"*".img" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/start"*".elf" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/fixup"*".dat" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/bootcode.bin" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/bcm"*".dtb" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  #cp -f "$OUTPUTDIR/mount_bootfs/config-display.txt" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$OUTPUTDIR/mount_bootfs/config-initramfs.txt" | tee "$OUTPUTDIR/mount_bootfs/config-initramfs.txt" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/config-initramfs.txt" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$OUTPUTDIR/mount_bootfs/config.txt" | tee "$OUTPUTDIR/mount_bootfs/config.txt" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/mount_bootfs/config.txt" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  cp -rf "$OUTPUTDIR/mount_bootfs/overlays" "$OUTPUTDIR/mount_rootfs/BOOT/" >/dev/null 2>&1
  return 0
}

function gen_system_folder () {
  function umount_sqfs () {
    sync >/dev/null 2>&1
    sleep 2
    umount "$OUTPUTDIR/mount_devel" >/dev/null 2>&1
    sync >/dev/null 2>&1
    sleep 2
    umount "$OUTPUTDIR/mount_sqfs" >/dev/null 2>&1
    sleep 2
    return 0
  }
  local exitcode=0
  if [ "$TARGET_SYS" == "mount_devel" ]; then
    local image=
    mkdir -p "$OUTPUTDIR/mount_devel"
    if ! mount -t squashfs "$OUTPUTDIR/mount_rootfs/IMAGES/$(format_image_load_images)/system.sqfs" "$OUTPUTDIR/mount_sqfs" >/dev/null 2>&1; then
      echo "mount /IMAGES/$(format_image_load_images)/system.sqfs failed!\n"
      exitcode=1
    fi
    sleep 2
    if ! mount -t overlay overlay \
      -o lowerdir="$OUTPUTDIR/mount_sqfs/SYSTEM",upperdir="$OUTPUTDIR/mount_rootfs/DATA/$(format_image_load_data)/devel_data/data",workdir="$OUTPUTDIR/mount_rootfs/DATA/$(format_image_load_data)/devel_data/work" "$OUTPUTDIR/mount_devel" >/dev/null 2>&1; then
      echo "mount developer data overlay failed!\n"
      exitcode=1
    fi
    sleep 2
    ! touch "$OUTPUTDIR/mount_devel/test.dummy" >/dev/null 2>&1 && echo "no write access in developer data overlay!\n" && exitcode=1
    rm -f "$OUTPUTDIR/mount_devel/test.dummy" >/dev/null 2>&1
  fi
  [ $exitcode -ne 0 ] && umount_sqfs && return $exitcode
  local imgldr_ver="$("$OUTPUTDIR/$TARGET_SYS/usr/bin/initramfs-imgldr" -v 2>/dev/null | perl -pe 'if(($v)=/([0-9]+([.][0-9]+)+)/){print"$v\n";exit}$_=""' 2>/dev/null)"
  ! compare_version "$imgldr_ver" "2.7" && echo "initramfs-imgldr is not installed on source or version is too old!\n" && exitcode=1
  [ $exitcode -ne 0 ] && umount_sqfs && return $exitcode
  ! cleanup_rootfs && echo "cleanup_rootfs failed!\n" && exitcode=1
  [ $exitcode -ne 0 ] && umount_sqfs && return $exitcode
  ! cleanup_target_system && echo "cleanup_target_system failed!\n" && exitcode=1
  [ $exitcode -ne 0 ] && umount_sqfs && return $exitcode
  rm -rf "$OUTPUTDIR/mount_rootfs/SYSTEM" >/dev/null 2>&1
  mkdir -p "$OUTPUTDIR/mount_rootfs/SYSTEM"
  find "$OUTPUTDIR/$TARGET_SYS" -maxdepth 1 -mindepth 1 -not -name 'SYSTEM' -not -name 'BOOT' -not -name 'INFO' -not -name 'IMAGES' -not -name 'CONFIG' -not -name 'DATA' -exec cp -arf {} "$OUTPUTDIR/mount_rootfs/SYSTEM" \;
  [ $? -ne 0 ] && echo "copy system files failed!\n" && exitcode=1
  umount_sqfs
  for sysfolder in bin lib sbin; do
    if [ -d "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" ]; then
      mkdir -p "$OUTPUTDIR/mount_rootfs/SYSTEM/usr/$sysfolder"
      mv -f "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder/"* "$OUTPUTDIR/mount_rootfs/SYSTEM/usr/$sysfolder/" >/dev/null 2>&1
    fi
    rm -rf "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
    ln -s usr/$sysfolder "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
  done
  for sysfolder in etc home media mnt opt root srv tmp; do
    if [ -d "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" ]; then
      mkdir -p "$OUTPUTDIR/mount_rootfs/SYSTEM/var/kiosk/$sysfolder"
      mv -f "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder/"* "$OUTPUTDIR/mount_rootfs/SYSTEM/var/kiosk/$sysfolder/" >/dev/null 2>&1
    fi
    rm -rf "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
    ln -s var/kiosk/$sysfolder "$OUTPUTDIR/mount_rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
  done
  return $exitcode
}

function gen_info_folder () {
  ! cleanup_rootfs && return 1
  rm -rf "$OUTPUTDIR/mount_rootfs/INFO" >/dev/null 2>&1
  mkdir -p "$OUTPUTDIR/mount_rootfs/INFO"
  cat >"$OUTPUTDIR/mount_rootfs/INFO/systeminfo" <<EOF
system=${BRANCH}
version=${VERSION}
update=${SERVER}
EOF
  chmod -f u=r,g=r,o=r "$OUTPUTDIR/mount_rootfs/INFO/systeminfo"
  if ls "$SCRIPTDIR/scripts/"* >/dev/null 2>&1; then
    ( cd "$SCRIPTDIR/scripts" && tar -cf "$OUTPUTDIR/mount_rootfs/INFO/scripts.tar" * >/dev/null 2>&1)
    [ -f "$OUTPUTDIR/mount_rootfs/INFO/scripts.tar" ] || return 1
  fi
}

function gen_system_image () {
  ! mount_devices >/dev/null 2>&1 && echo "mount failed!" && return 1
  ! gen_system_folder && echo "create SYSTEM folder failed!" && return 1
  ! gen_boot_folder && echo "create BOOT folder failed!" && return 1
  ! gen_info_folder && echo "create INFO folder failed!" && return 1
  find "$OUTPUTDIR/mount_rootfs" -maxdepth 1 -mindepth 1 -not -name 'SYSTEM' -not -name 'BOOT' -not -name 'INFO' -exec rm -rf {} \;
  mksquashfs "$OUTPUTDIR/mount_rootfs" "$OUTPUTDIR/system.sqfs" >/dev/null 2>&1
  set_base_perms "$OUTPUTDIR/images"
  return 0
}

function gen_main_image () {
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  echo "console=tty1 root=PARTUUID=${DISKID}-02 rootfstype=ext4 fsck.repair=yes rootwait FIRSTBOOT fastboot logo.nologo loglevel=3" > "$OUTPUTDIR/mount_bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
  local default_target="multi-user.target"
  mount -t squashfs "$OUTPUTDIR/system.sqfs" "$OUTPUTDIR/mount_sqfs" >/dev/null 2>&1
  if [ -e "$OUTPUTDIR/mount_sqfs/SYSTEM/usr/lib/systemd/system/default.target" ]; then
    default_target="$(readlink -f "$OUTPUTDIR/mount_sqfs/SYSTEM/usr/lib/systemd/system/default.target")"
    default_target="$(basename "$default_target")"
  fi
  cool_down
  umount "$OUTPUTDIR/mount_sqfs" >/dev/null 2>&1
  if [ "$default_target" == "graphical.target" ]; then
    sed -i 's/$/ vt.global_cursor_default=0/g' "$OUTPUTDIR/mount_bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ splash/g' "$OUTPUTDIR/mount_bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ quiet/g' "$OUTPUTDIR/mount_bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
  fi
  if [ -f "$OUTPUTDIR/mount_bootfs/config-custom.txt" ]; then
    rm -f "$OUTPUTDIR/mount_bootfs/config-custom.txt"
    touch "$OUTPUTDIR/mount_bootfs/config-custom.txt"
  fi
  expand_device $ROOT_NUM $MAIN_END
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  rm -rf "$OUTPUTDIR/mount_rootfs/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/mount_rootfs/"* >/dev/null 2>&1
  mkdir "$OUTPUTDIR/mount_rootfs/CONFIG" "$OUTPUTDIR/mount_rootfs/IMAGES" "$OUTPUTDIR/mount_rootfs/DATA/BASE_IMAGE/config" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/system.sqfs" "$OUTPUTDIR/mount_rootfs/IMAGES/$(format_image_load_images)/system.sqfs" >/dev/null 2>&1
  echo "BASE_IMAGE" > "$OUTPUTDIR/mount_rootfs/CONFIG/image_load" || echo "root: write image_load file failed!"
  echo "true" > "$OUTPUTDIR/mount_rootfs/CONFIG/auto_cleanup" || echo "root: write auto_cleanup file failed!"
  echo "RAMDISK" > "$OUTPUTDIR/mount_rootfs/DATA/BASE_IMAGE/config/mode" || echo "root: write mode file failed!"
  echo "NONE" > "$OUTPUTDIR/mount_rootfs/DATA/BASE_IMAGE/config/reset" || echo "root: write reset file failed!"
  cleanup_rootfs
  shrink_device $ROOT_NUM $ROOT_START
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  dd if=/dev/zero of="$OUTPUTDIR/mount_bootfs/tmpzero.txt" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/mount_bootfs/tmpzero.txt" >/dev/null 2>&1
  dd if=/dev/zero of="$OUTPUTDIR/mount_rootfs/tmpzero.txt" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/mount_rootfs/tmpzero.txt" >/dev/null 2>&1
  umount_devices >/dev/null 2>&1
  dd if=$MAIN_DEV status=none bs=512 count=$(fdisk -l | awk '$1 == "'$ROOT_DEV'" { print $3 }') | xz -1c > "$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.img.xz"
  expand_device $ROOT_NUM $ROOT_END
  mv -f "$OUTPUTDIR/system.sqfs" "$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.system.sqfs"
  cat >"$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.update.conf" <<EOF
system=${BRANCH}
version=${VERSION}
download={DOWNLOAD_LINK}
checksum={SHA512SUM}
EOF
  set_base_perms "$RELEASEDIR"
  return 0
}

function cmd_run() {
  printf "\033c"
  local result
  EXITCODE=0
  infobox "Check superuser... "
  check_superuser || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Create folders..."
  result=$(create_folders)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Check prereqs... "
  check_commands || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Check device... "
  check_getvar_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Generate system.sqfs..."
  result=$(gen_system_image)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Generate main image..."
  result=$(gen_main_image)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  echo "no errors!" >> "$LOGFILE"
  return 0
}

function cmd_basefiles() {
  printf "\033c"
  local result
  EXITCODE=0
  infobox "Check superuser... "
  check_superuser || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Create folders..."
  result=$(create_folders)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Check prereqs... "
  check_commands || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Check device... "
  check_getvar_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Mount device..."
  ! mount_devices >/dev/null 2>&1 && msgbox "mounting failed!" && return 1
  infobox "Copy files..."
  if ls "$SCRIPTDIR/$BASE_BOOT/"* >/dev/null 2>&1; then
    set_base_perms "$SCRIPTDIR/$BASE_BOOT"
    cd $SCRIPTDIR/$BASE_BOOT >/dev/null 2>&1
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$OUTPUTDIR/mount_bootfs" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_BOOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1; then
    set_base_perms "$SCRIPTDIR/$BASE_ROOT"
    cd $SCRIPTDIR/$BASE_ROOT >/dev/null 2>&1
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$OUTPUTDIR/mount_rootfs" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_ROOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if [ -f "$OUTPUTDIR/mount_rootfs/IMAGES/$(format_image_load_images)/system.sqfs" ]; then
    echo "DEVELOPER" > "$OUTPUTDIR/mount_rootfs/DATA/$(format_image_load_data)/config/mode"
  fi
  umount_devices >/dev/null 2>&1
  [ "$result" != "" ] && printf "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  echo "no errors!" >> "$LOGFILE"
  return 0
}

function get_disklist() {
  local root_dev=$(lsblk --noheadings --paths --output PKNAME $( findmnt --noheadings --output SOURCE --mountpoint / ))
  local device_short
  local device
  while IFS= read -r -d $'\0' device; do
    if [ "$root_dev" != "$device" ]; then
      device_short=${device/\/dev\//}
      echo $device_short
      echo "$device     "
      [ "$device_short" == "$DEVICE" ] && echo "ON" || echo "OFF"
    fi
  done < <(find "/dev/" -regex '/dev/sd[a-z]\|/dev/vd[a-z]\|/dev/hd[a-z]' -print0)
}

function infobox(){
  local terminal
  printenv DISPLAY >/dev/null 2>&1 && terminal="vt220" || terminal="ansi"
  local bash_lines=$(tput lines)
  local bash_columns=$(tput cols)
  printf "\033c"
  TERM=$terminal whiptail --title "Information" --infobox "$1" $(( $bash_lines - 16 )) $(( $bash_columns - 8 ))
}

function msgbox(){
  local bash_lines=$(tput lines)
  local bash_columns=$(tput cols)
  printf "\033c"
  whiptail --title "Information" --msgbox "$1" $(( $bash_lines - 12 )) $(( $bash_columns - 8 ))
}

function cmd_menu() {
  local bash_lines
  local bash_columns
  local menu_sel
  local menu_sub_sel
  local disklist
  local device
  local branch
  local version
  local server
  local start_runable
  local base_runable
  check_superuser || echo "Could not start: $FAIL_REASON"
  [ $EXITCODE -ne 0 ] && return $EXITCODE
  check_commands || echo "Could not start: $FAIL_REASON"
  [ $EXITCODE -ne 0 ] && return $EXITCODE
  config_read_all
  while true
  do
    printf "\033c"
    bash_lines=$(tput lines)
    bash_columns=$(tput cols)
    [ -n "$DEVICE" ] && device=$DEVICE || device="unset"
    [ -n "$BRANCH" ] && branch=$BRANCH || branch="unset"
    [ -n "$VERSION" ] && version=$VERSION || version="unset"
    [ -n "$SERVER" ] && server=$SERVER || server="unset"
    [ -n "$DEVICE" ] && [ -n "$BRANCH" ] && [ -n "$VERSION" ] && start_runable="START" || start_runable="N/A"
    [ -n "$DEVICE" ] && ( ls "$SCRIPTDIR/$BASE_BOOT/"* >/dev/null 2>&1 || ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1 ) && base_runable="BASEFILES" || base_runable="N/A"
    menu_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" \
      --menu "" \
      $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) $(( $bash_lines - 15 )) \
      "DEVICE  " "$device" \
      "BRANCH  " "$branch" \
      "VERSION  " "$version" \
      "SERVER  " "$server" \
      "BASE_BOOT  " "$BASE_BOOT" \
      "BASE_ROOT  " "$BASE_ROOT" \
      "  " "" \
      "$start_runable  " "start creating images" \
      "$base_runable  " "copy basefiles to disk" 3>&1 1>&2 2>&3)
    case $menu_sel in
      1)
        #
      ;;
      "DEVICE  ")
        disklist=$(get_disklist)
        if [ "${disklist}" != "" ]; then
          menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --radiolist \
            "Choose disk:" \
            $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) $(( $bash_lines - 15 )) \
            $disklist 3>&1 1>&2 2>&3)
          DEVICE=$menu_sub_sel
        else
          msgbox "Could not find any drives except root drive!"
          DEVICE=""
        fi
      ;;
      "BRANCH  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input BRANCH:" \
          $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) \
          "$BRANCH" 3>&1 1>&2 2>&3)
        BRANCH=$menu_sub_sel
      ;;
      "VERSION  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input VERSION:" \
          $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) \
          "$VERSION" 3>&1 1>&2 2>&3)
        VERSION=$menu_sub_sel
      ;;
      "SERVER  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input SERVER:" \
          $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) \
          "$SERVER" 3>&1 1>&2 2>&3)
        SERVER=$menu_sub_sel
      ;;
      "BASE_BOOT  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input BASE_BOOT:" \
          $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) \
          "$BASE_BOOT" 3>&1 1>&2 2>&3)
        BASE_BOOT=$menu_sub_sel
      ;;
      "BASE_ROOT  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input BASE_ROOT:" \
          $(( $bash_lines - 8 )) $(( $bash_columns - 8 )) \
          "$BASE_ROOT" 3>&1 1>&2 2>&3)
        BASE_ROOT=$menu_sub_sel
      ;;
      "START  ")
        cmd_run
        [ $? -eq 0 ] && msgbox "success" || msgbox "no success (see logfile!)"
      ;;
      "BASEFILES  ")
        cmd_basefiles
        [ $? -eq 0 ] && msgbox "success" || msgbox "no success (see logfile!)"
      ;;
      "N/A  ")
        msgbox "Configuration not fully set!\nCould not start!"
      ;;
      *)
        printf "\033c"
        exit $EXITCODE
      ;;
    esac
  done
}

function cmd_print_version() {
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
}

function cmd_print_help() {
  echo "Usage: $SCRIPTNAME [OPTION]"
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
  echo " "
  echo "-D={DEVICE}             needed; select device"
  echo "-B={BRANCH}             needed; set branch"
  echo "-V={VERSION}            needed; set version"
  echo "-S={SERVER}             optional; set updateserver"
  echo "-C={CONFIG}             optional; load config file from {scriptdir}"
  echo "-v, --version           print version info and exit"
  echo "-h, --help              print this help and exit"
  echo " "
  echo "If not all needed informations was given then opens menu"
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "MENU" ]] && cmd_menu

exit $EXITCODE
