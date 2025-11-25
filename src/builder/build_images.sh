#!/usr/bin/sudo bash
##############################################
##                                          ##
##  build_images.sh                         ##
##                                          ##
##############################################

#get some variables
export LC_ALL=C
export LANG=C
SCRIPT_TITLE="build image"
SCRIPT_VERSION="1.3.1"
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
  touch "$OUTPUTDIR/boot_mount/test.dummy" >/dev/null 2>&1 || exitcode=1
  touch "$OUTPUTDIR/root_mount/test.dummy" >/dev/null 2>&1 || exitcode=1
  rm -f "$OUTPUTDIR/boot_mount/test.dummy" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/root_mount/test.dummy" >/dev/null 2>&1
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
  mount -w $BOOT_DEV "$OUTPUTDIR/boot_mount" >/dev/null 2>&1
  [ $? -ne 0 ] && exitcode=1
  mount -w $ROOT_DEV "$OUTPUTDIR/root_mount" >/dev/null 2>&1
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

function create_install_script () {
  cat <<EOF | sudo tee "$OUTPUTDIR/images/install_update" >/dev/null 2>&1
#!/bin/sh
install_boot() {
  mkdir -p /mnt/sysimg /mnt/oemimg
  mount -r -t ext4 /mnt/tmproot/IMAGES/update/system.img /mnt/sysimg >/dev/null 2>&1
  [ -f "/mnt/tmproot/IMAGES/update/oem.img" ] && mount -r -t ext4 /mnt/tmproot/IMAGES/update/oem.img /mnt/oemimg >/dev/null 2>&1
  if [ -f /mnt/tmproot/IMAGES/update/oem.img ] && ls /mnt/oemimg/BOOT/* >/dev/null 2>&1; then
    find /mnt/oemimg/BOOT -maxdepth 1 -mindepth 1 -exec cp -rf {} /mnt/tmpboot/ \;
  elif ls /mnt/sysimg/BOOT/* >/dev/null 2>&1; then
    find /mnt/sysimg/BOOT -maxdepth 1 -mindepth 1 -exec cp -rf {} /mnt/tmpboot/ \;
  fi
  sync >/dev/null 2>&1
  umount /mnt/sysimg >/dev/null 2>&1
  umount /mnt/oemimg >/dev/null 2>&1
  return 0
}
install_images() {
  find /mnt/tmproot/IMAGES -maxdepth 1 -mindepth 1 -not -name 'update' -exec rm -rf {} \;
  find /mnt/tmproot/IMAGES/update -maxdepth 1 -mindepth 1 -not -name 'install_update' -not -name 'update' -exec mv -f {} /mnt/tmproot/IMAGES/ \;
  rm -rf /mnt/tmproot/SETUP >/dev/null 2>&1
  rm -rf /mnt/tmproot/OEM >/dev/null 2>&1
  rm -rf /mnt/tmproot/OVERLAY/data >/dev/null 2>&1
  return 0
}
install_boot
install_images
exit 0
EOF
  echo $(sha512sum "$OUTPUTDIR/images/install_update" | awk 'NR==1 {print $1}') > "$OUTPUTDIR/images/install_update.sha512"
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
  mkdir -p "$OUTPUTDIR/boot_mount"
  mkdir -p "$OUTPUTDIR/root_mount"
  mkdir -p "$OUTPUTDIR/image_mount"
  mkdir -p "$OUTPUTDIR/images"
  mkdir -p "$RELEASEDIR/update"
  [ -f "$LOGFILE" ] && rm -f "$LOGFILE"
  printf "Log File - " >> "$LOGFILE" && date >> "$LOGFILE"
  set_base_perms "$OUTPUTDIR"
  set_base_perms "$RELEASEDIR"
  return 0
}

function gen_boot_folder () {
  ! ls "$OUTPUTDIR/boot_mount/"* >/dev/null 2>&1 && return 1
  rm -rf "$OUTPUTDIR/root_mount/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/lost+found/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/tmp/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/var/tmp/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/BOOT" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/lost+found/"* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/boot_mount/FSCK"*".REC" >/dev/null 2>&1
  mkdir -p "$OUTPUTDIR/root_mount/BOOT"
  cp -f "$OUTPUTDIR/boot_mount/initramfs"* "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/kernel"*".img" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/start"*".elf" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/fixup"*".dat" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/bootcode.bin" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/bcm"*".dtb" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  #cp -f "$OUTPUTDIR/boot_mount/config-display.txt" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$OUTPUTDIR/boot_mount/config-initramfs.txt" | tee "$OUTPUTDIR/boot_mount/config-initramfs.txt" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/config-initramfs.txt" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$OUTPUTDIR/boot_mount/config.txt" | tee "$OUTPUTDIR/boot_mount/config.txt" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/boot_mount/config.txt" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  cp -rf "$OUTPUTDIR/boot_mount/overlays" "$OUTPUTDIR/root_mount/BOOT/" >/dev/null 2>&1
  return 0
}

function gen_system () {
  ! mount_devices >/dev/null 2>&1 && echo "mount failed!" && return 1
  local imgldr_ver="$("$OUTPUTDIR/root_mount/usr/bin/initramfs-imgldr" -v 2>/dev/null | perl -pe 'if(($v)=/([0-9]+([.][0-9]+)+)/){print"$v\n";exit}$_=""' 2>/dev/null)"
  if [ -f "$OUTPUTDIR/root_mount/IMAGES/system.img" ]; then
    cp -f "$OUTPUTDIR/root_mount/IMAGES/system.img" "$OUTPUTDIR/images/system.img" >/dev/null 2>&1
    umount_devices >/dev/null 2>&1
  elif compare_version "$imgldr_ver" "2.5"; then
    ! gen_boot_folder && echo "create bootfolder failed!" && return 1
    mkdir -p "$OUTPUTDIR/root_mount/SYSTEM" "$OUTPUTDIR/root_mount/INFO"
    find "$OUTPUTDIR/root_mount" -maxdepth 1 -mindepth 1 -not -name 'SYSTEM' -not -name 'BOOT' -not -name 'INFO' -exec mv -f {} "$OUTPUTDIR/root_mount/SYSTEM" \;
    ! echo "${BRANCH} ${VERSION}" > "$OUTPUTDIR/root_mount/INFO/sysinfo" && echo "root: write sysinfo failed!" && return 1
    chmod -f u=r,g=r,o=r "$OUTPUTDIR/root_mount/INFO/sysinfo"
    if [ -n "${SERVER}" ]; then
      ! echo "${SERVER}" > "$OUTPUTDIR/root_mount/INFO/updateserver" && echo "root: write updateserver failed!" && return 1
      chmod -f u=r,g=r,o=r "$OUTPUTDIR/root_mount/INFO/updateserver"
    fi
    if [ -f "$OUTPUTDIR/root_mount/SYSTEM/usr/lib/initramfs-imgldr/imgldr-install_update" ]; then
      cp -af "$OUTPUTDIR/root_mount/SYSTEM/usr/lib/initramfs-imgldr/imgldr-install_update" "$OUTPUTDIR/root_mount/INFO/install_update" >/dev/null 2>&1
    fi
    shrink_device $ROOT_NUM $ROOT_START
    ! mount_devices >/dev/null 2>&1 && echo "mount failed!" && return 1
    e4defrag $ROOT_DEV >/dev/null 2>&1
    dd if=/dev/zero of="$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
    rm -f "$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
    umount_devices >/dev/null 2>&1
    dd conv=sparse if="$ROOT_DEV" of="$OUTPUTDIR/images/system.img" >/dev/null 2>&1
    e2fsck -f -y "$OUTPUTDIR/images/system.img" >/dev/null 2>&1
    resize2fs -M "$OUTPUTDIR/images/system.img" >/dev/null 2>&1
    expand_device $ROOT_NUM $ROOT_END
  else
    echo "no system image found and initramfs-imgldr is not installed on source device or version is too old!"
    umount_devices >/dev/null 2>&1
  fi
  set_base_perms "$OUTPUTDIR/images"
  return 0
}

function gen_oem () {
  ! mount_devices >/dev/null 2>&1 && echo "mount failed!" && return 1
  if [ -f "$OUTPUTDIR/images/system.img" ] && ls "$OUTPUTDIR/root_mount/OEM/"* >/dev/null 2>&1; then
    ! gen_boot_folder && echo "create bootfolder failed!" && return 1
    mkdir -p "$OUTPUTDIR/root_mount/INFO"
    find "$OUTPUTDIR/root_mount" -maxdepth 1 -mindepth 1 -not -name 'OEM' -not -name 'BOOT' -not -name 'INFO' -exec rm -rf {} \;
    mv -f "$OUTPUTDIR/root_mount/OEM" "$OUTPUTDIR/root_mount/SYSTEM"
    if [ -f "$OUTPUTDIR/root_mount/SYSTEM/usr/lib/initramfs-imgldr/imgldr-install_update" ]; then
      cp -af "$OUTPUTDIR/root_mount/SYSTEM/usr/lib/initramfs-imgldr/imgldr-install_update" "$OUTPUTDIR/root_mount/INFO/install_update" >/dev/null 2>&1
    fi
    mount -r -t ext4 "$OUTPUTDIR/images/system.img" "$OUTPUTDIR/image_mount"
    cp -af "$OUTPUTDIR/image_mount/INFO/sysinfo" "$OUTPUTDIR/root_mount/INFO/sysinfo" >/dev/null 2>&1
    cool_down
    umount "$OUTPUTDIR/image_mount" >/dev/null 2>&1
    ! echo "${BRANCH} ${VERSION}" > "$OUTPUTDIR/root_mount/INFO/oeminfo" && echo "root: write oeminfo failed!" && return 1
    chmod -f u=r,g=r,o=r "$OUTPUTDIR/root_mount/INFO/oeminfo"
    if [ -n "${SERVER}" ]; then
      ! echo "${SERVER}" > "$OUTPUTDIR/root_mount/INFO/updateserver" && echo "root: write updateserver failed!" && return 1
      chmod -f u=r,g=r,o=r "$OUTPUTDIR/root_mount/INFO/updateserver"
    fi
    shrink_device $ROOT_NUM $ROOT_START
    ! mount_devices >/dev/null 2>&1 && echo "mount failed!" && return 1
    e4defrag $ROOT_DEV >/dev/null 2>&1
    dd if=/dev/zero of="$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
    rm -f "$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
    umount_devices >/dev/null 2>&1
    dd conv=sparse if="$ROOT_DEV" of="$OUTPUTDIR/images/oem.img" >/dev/null 2>&1
    e2fsck -f -y "$OUTPUTDIR/images/oem.img" >/dev/null 2>&1
    resize2fs -M "$OUTPUTDIR/images/oem.img" >/dev/null 2>&1
    expand_device $ROOT_NUM $ROOT_END
    set_base_perms "$OUTPUTDIR/images"
  elif [ -f "$OUTPUTDIR/images/system.img" ] && [ -f "$OUTPUTDIR/root_mount/IMAGES/oem.img" ]; then
    cp -f "$OUTPUTDIR/root_mount/IMAGES/oem.img" "$OUTPUTDIR/images/oem.img" >/dev/null 2>&1
    umount_devices >/dev/null 2>&1
  else
    umount_devices >/dev/null 2>&1
  fi
  return 0
}

function gen_image () {
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  echo "console=serial0,115200 console=tty1 root=PARTUUID=${DISKID}-02 rootfstype=ext4 fsck.repair=yes rootwait FIRSTBOOT fastboot boot=image logo.nologo loglevel=3" > "$OUTPUTDIR/boot_mount/cmdline.txt" || echo "boot: write cmdline failed!"
  local default_target="multi-user.target"
  mount -r -t ext4 "$OUTPUTDIR/images/system.img" "$OUTPUTDIR/image_mount"
  if [ -e "$OUTPUTDIR/image_mount/SYSTEM/usr/lib/systemd/system/default.target" ]; then
    default_target="$(readlink -f "$OUTPUTDIR/image_mount/SYSTEM/usr/lib/systemd/system/default.target")"
    default_target="$(basename "$default_target")"
  fi
  cool_down
  umount "$OUTPUTDIR/image_mount" >/dev/null 2>&1
  if [ -f "$OUTPUTDIR/images/oem.img" ]; then
    mount -r -t ext4 "$OUTPUTDIR/images/oem.img" "$OUTPUTDIR/image_mount"
    if [ -e "$OUTPUTDIR/image_mount/SYSTEM/usr/lib/systemd/system/default.target" ]; then
      default_target="$(readlink -f "$OUTPUTDIR/image_mount/SYSTEM/usr/lib/systemd/system/default.target")"
      default_target="$(basename "$default_target")"
    fi
    cool_down
    umount "$OUTPUTDIR/image_mount" >/dev/null 2>&1
  fi
  if [ "$default_target" == "graphical.target" ]; then
    sed -i 's/$/ vt.global_cursor_default=0/g' "$OUTPUTDIR/boot_mount/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ splash/g' "$OUTPUTDIR/boot_mount/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ quiet/g' "$OUTPUTDIR/boot_mount/cmdline.txt" || echo "boot: write cmdline failed!"
  fi
  #echo "console=serial0,115200 console=tty1 root=PARTUUID=${DISKID}-02 rootfstype=ext4 fsck.repair=yes rootwait quiet FIRSTBOOT fastboot boot=image logo.nologo splash loglevel=3 vt.global_cursor_default=0" > "$OUTPUTDIR/boot_mount/cmdline.txt" || echo "boot: write cmdline failed!"
  if [ -f "$OUTPUTDIR/boot_mount/config-custom.txt" ]; then
    rm -f "$OUTPUTDIR/boot_mount/config-custom.txt"
    touch "$OUTPUTDIR/boot_mount/config-custom.txt"
  fi
  expand_device $ROOT_NUM $MAIN_END
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  rm -rf "$OUTPUTDIR/root_mount/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/"* >/dev/null 2>&1
  mkdir "$OUTPUTDIR/root_mount/CONFIG" "$OUTPUTDIR/root_mount/IMAGES" "$OUTPUTDIR/root_mount/STORAGE" "$OUTPUTDIR/root_mount/STATIC" "$OUTPUTDIR/root_mount/OVERLAY" >/dev/null 2>&1
  cp -f "$OUTPUTDIR/images/system.img" "$OUTPUTDIR/root_mount/IMAGES/system.img" >/dev/null 2>&1
  [ -f "$OUTPUTDIR/images/oem.img" ] && cp -f "$OUTPUTDIR/images/oem.img" "$OUTPUTDIR/root_mount/IMAGES/oem.img" >/dev/null 2>&1
  echo "KIOSK_ACTIVE=true" > "$OUTPUTDIR/root_mount/STATIC/rpi-kiosk_states" || echo "boot: write rpi-kiosk_states failed!"
  echo "KIOSK_ADMINMODE=false" >> "$OUTPUTDIR/root_mount/STATIC/rpi-kiosk_states" || echo "boot: write rpi-kiosk_states failed!"
  #touch "$OUTPUTDIR/root_mount/STATIC/auto-reboot-service_poweroff"
  echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$OUTPUTDIR/root_mount/STATIC/fake-hwclock" || echo "root: write fake-hwclock failed!"
  chmod 644 "$OUTPUTDIR/root_mount/STATIC/fake-hwclock"
  date +%s > "$OUTPUTDIR/root_mount/STATIC/clock" || echo "root: write clock failed!"
  chmod 644 "$OUTPUTDIR/root_mount/STATIC/clock"
  rm -rf "$OUTPUTDIR/root_mount/System Volume Information" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/.Trash-1000" >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/lost+found/."* >/dev/null 2>&1
  rm -rf "$OUTPUTDIR/root_mount/lost+found/"* >/dev/null 2>&1
  shrink_device $ROOT_NUM $ROOT_START
  mount_devices >/dev/null 2>&1 || echo "mount failed!"
  dd if=/dev/zero of="$OUTPUTDIR/boot_mount/tmpzero.txt" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/boot_mount/tmpzero.txt" >/dev/null 2>&1
  dd if=/dev/zero of="$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
  rm -f "$OUTPUTDIR/root_mount/tmpzero.txt" >/dev/null 2>&1
  umount_devices >/dev/null 2>&1
  dd if=$MAIN_DEV status=none bs=512 count=$(fdisk -l | awk '$1 == "'$ROOT_DEV'" { print $3 }') | xz -1c > "$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.img.xz"
  expand_device $ROOT_NUM $ROOT_END
  set_base_perms "$OUTPUTDIR/images"
  set_base_perms "$RELEASEDIR"
  return 0
}

function gen_update () {
  echo $(sha512sum "$OUTPUTDIR/images/system.img" | awk 'NR==1 {print $1}') > "$OUTPUTDIR/images/system.img.sha512"
  [ -f "$OUTPUTDIR/images/oem.img" ] && echo $(sha512sum "$OUTPUTDIR/images/oem.img" | awk 'NR==1 {print $1}') > "$OUTPUTDIR/images/oem.img.sha512"
  cd "$OUTPUTDIR/images" >/dev/null 2>&1
  rm -f "$RELEASEDIR/update/kiosk-os_SYS_${BRANCH}-v${VERSION}.zip" >/dev/null 2>&1
  rm -f "$RELEASEDIR/update/kiosk-os_OEM_${BRANCH}-v${VERSION}.zip" >/dev/null 2>&1
  zip "$RELEASEDIR/update/kiosk-os_SYS_${BRANCH}-v${VERSION}.zip" "system.img" "system.img.sha512" "install_update" "install_update.sha512" >/dev/null 2>&1
  [ -f "$OUTPUTDIR/images/oem.img" ] && zip "$RELEASEDIR/update/kiosk-os_OEM_${BRANCH}-v${VERSION}.zip" "oem.img" "oem.img.sha512" "install_update" "install_update.sha512" >/dev/null 2>&1
  cd "$SCRIPTDIR" >/dev/null 2>&1
  local script_installed="false"
  mount -r -t ext4 "$OUTPUTDIR/images/system.img" "$OUTPUTDIR/image_mount"
  [ -f "$OUTPUTDIR/image_mount/INFO/install_update" ] && script_installed="true"
  local BRANCH_SYS="$(awk 'NR==1 {print $1}' "$OUTPUTDIR/image_mount/INFO/sysinfo" 2>/dev/null)"
  local VERSION_SYS="$(awk 'NR==1 {print $2}' "$OUTPUTDIR/image_mount/INFO/sysinfo" 2>/dev/null)"
  cool_down
  umount "$OUTPUTDIR/image_mount" >/dev/null 2>&1
  if [ "$script_installed" == "false" ] && [ -f "$OUTPUTDIR/images/oem.img" ]; then
    mount -r -t ext4 "$OUTPUTDIR/images/oem.img" "$OUTPUTDIR/image_mount"
    [ -f "$OUTPUTDIR/image_mount/INFO/install_update" ] && script_installed="true"
    cool_down
    umount "$OUTPUTDIR/image_mount" >/dev/null 2>&1
  fi
  [ "$script_installed" == "false" ] && create_install_script && script_installed="true"
  local sha512sum_OEM=$(sha512sum "$RELEASEDIR/update/kiosk-os_OEM_${BRANCH}-v${VERSION}.zip" 2>/dev/null | awk 'NR==1 {print $1}')
  local sha512sum_SYS=$(sha512sum "$RELEASEDIR/update/kiosk-os_SYS_${BRANCH}-v${VERSION}.zip" 2>/dev/null | awk 'NR==1 {print $1}')
  [ -n "$sha512sum_OEM" ] && echo "$sha512sum_OEM" > "$RELEASEDIR/update/kiosk-os_OEM_${BRANCH}-v${VERSION}.zip.sha512" || sha512sum_OEM=$sha512sum_SYS
  echo "$sha512sum_SYS" > "$RELEASEDIR/update/kiosk-os_SYS_${BRANCH}-v${VERSION}.zip.sha512"
  echo "upd_version=$VERSION" > "$RELEASEDIR/update/${BRANCH}.config"
  echo "upd_branch=$BRANCH" >> "$RELEASEDIR/update/${BRANCH}.config"
  echo "upd_download={DOWNLOAD_LINK}" >> "$RELEASEDIR/update/${BRANCH}.config"
  echo "upd_checksum=$sha512sum_OEM" >> "$RELEASEDIR/update/${BRANCH}.config"
  if [ -f "$OUTPUTDIR/images/oem.img" ] && [ "$VERSION_SYS" != "" ]; then
    echo "upd_sys_version=$VERSION_SYS" >> "$RELEASEDIR/update/${BRANCH}.config"
    echo "upd_sys_branch=$BRANCH_SYS" >> "$RELEASEDIR/update/${BRANCH}.config"
    echo "upd_sys_download={DOWNLOAD_LINK}" >> "$RELEASEDIR/update/${BRANCH}.config"
    echo "upd_sys_checksum=$sha512sum_SYS" >> "$RELEASEDIR/update/${BRANCH}.config"
  fi
  set_base_perms "$OUTPUTDIR/images"
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
  infobox "Generate system.img..."
  result=$(gen_system)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Generate oem.img..."
  result=$(gen_oem)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Generate main image..."
  result=$(gen_image)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  infobox "Generate update pack..."
  result=$(gen_update)
  [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
  echo "no errors!" >> "$LOGFILE"
  return 0
}

function cmd_basefiles() {
  printf "\033c"
  local result
  EXITCODE=0
  # infobox "Check files... "
  # if ! ls "$SCRIPTDIR/$BASE_BOOT/"* >/dev/null 2>&1 && ! ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1; then
  #   result="No source files found!\n{SCRIPT_DIR}/$BASE_BOOT\n{SCRIPT_DIR}/$BASE_ROOT"
  # fi
  # [ "$result" != "" ] && echo "$result" >> "$LOGFILE" && msgbox "$result" && return 1
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
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$OUTPUTDIR/boot_mount" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_BOOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1; then
    set_base_perms "$SCRIPTDIR/$BASE_ROOT"
    cd $SCRIPTDIR/$BASE_ROOT >/dev/null 2>&1
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$OUTPUTDIR/root_mount" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_ROOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if [ -f "$OUTPUTDIR/root_mount/IMAGES/system.img" ]; then
    sed -i 's|SETUPMODE[^ ]* \{0,1\}||g' "$OUTPUTDIR/boot_mount/cmdline.txt"
    sed -i 's|[ \t]*$||' "$OUTPUTDIR/boot_mount/cmdline.txt"
    sed -i 's/$/ SETUPMODE/g' "$OUTPUTDIR/boot_mount/cmdline.txt"
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
