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
BUILDDIR="$SCRIPTDIR/build"
RELEASEDIR="$SCRIPTDIR/release"
CONFIGFILE="$SCRIPTDIR/$SCRIPTBASENAME.conf"
USERID="${SUDO_UID:-$UID}"
GROUPID="$(id -g $USERID)"
LOGFILE="$BUILDDIR/build.log"
FAIL_REASON=""
ROOT_DEV="NOT_MOUNTED"
BOOT_DEV="NOT_MOUNTED"
LOOP_DEV="NOT_MOUNTED"
EXITCODE=0

#check commands
for i in "$@"
do
  case $i in
    -i=*)
    IMAGE_LOAD=${i#-i=}
    shift # past argument
    ;;
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

function format_image_load() {
  case "${IMAGE_LOAD}" in
    BASE_IMAGE) echo "." ;;
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
  [ -z "$IMAGE_LOAD" ] && IMAGE_LOAD=$(config_read "$CONFIGFILE" IMAGE_LOAD "")
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

function check_superuser () {
  if [ $UID -ne 0 ]; then
    FAIL_REASON="not superuser"
    EXITCODE=1 && return $EXITCODE
  fi
  return 0
}

function check_commands () {
  local cmd=""
  for cmd in grep cut sed parted fdisk findmnt resize2fs e2fsck tune2fs zip md5sum sha512sum whiptail; do
    if ! command -v $cmd >/dev/null; then
      FAIL_REASON="$cmd not found"
      EXITCODE=1 && return $EXITCODE
    fi
  done
  return 0
}

function create_folders () {
  umount_main_img
  umount_main_dev
  rm -rf "$BUILDDIR"
  mkdir -p "$BUILDDIR/mount_bootfs"
  mkdir -p "$BUILDDIR/mount_rootfs"
  mkdir -p "$BUILDDIR/mount_sqfs/base"
  mkdir -p "$BUILDDIR/mount_sqfs/devel"
  mkdir -p "$BUILDDIR/mount_final/bootfs"
  mkdir -p "$BUILDDIR/mount_final/rootfs"
  mkdir -p "$BUILDDIR/images"
  mkdir -p "$RELEASEDIR"
  [ -f "$LOGFILE" ] && rm -f "$LOGFILE"
  printf "Log File - " >> "$LOGFILE" && date >> "$LOGFILE"
  set_base_perms "$BUILDDIR"
  set_base_perms "$RELEASEDIR"
  return 0
}

function create_main_img () {
  local image_name="kiosk_os.img"
  local image_size=4096
  local boot_size=512
  dd if=/dev/zero of="$BUILDDIR/images/${image_name}" bs=1M count=${image_size} status=progress >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not create ${image_name}" && EXITCODE=1 && return $EXITCODE
  sfdisk "$BUILDDIR/images/${image_name}" >/dev/null 2>&1 <<EOF
,${boot_size}M,c,*
,,83,
EOF
  [ $? -ne 0 ] && FAIL_REASON="could not create ${image_name}" && EXITCODE=1 && return $EXITCODE
  local loop_dev=$(losetup -P -f --show "$BUILDDIR/images/${image_name}")
  mkfs.vfat -F 32 -n "bootfs" "${loop_dev}p1" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not create partition 'bootfs'" && EXITCODE=1
  mkfs.ext4 -L "rootfs" "${loop_dev}p2" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not create partition 'rootfs'" && EXITCODE=1
  DISKID=$(fdisk -l "${loop_dev}" | sed -n 's/Disk identifier: 0x\([^ ]*\)/\1/p')
  losetup -d "${loop_dev}" >/dev/null 2>&1
  return $EXITCODE
}

function umount_main_img () {
  cool_down
  umount -f "$BUILDDIR/mount_final/bootfs" >/dev/null 2>&1
  umount -f "$BUILDDIR/mount_final/rootfs" >/dev/null 2>&1
  cool_down
  losetup -d "${LOOP_DEV}" >/dev/null 2>&1
  sleep 2
  LOOP_DEV="NOT_MOUNTED"
  return 0
}

function mount_main_img () {
  umount_main_img
  local image_name="kiosk_os.img"
  LOOP_DEV=$(losetup -P -f --show "$BUILDDIR/images/${image_name}")
  mount -o x-gvfs-hide -w "${LOOP_DEV}p1" "$BUILDDIR/mount_final/bootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not mount final bootfs" && EXITCODE=1
  mount -o x-gvfs-hide -w "${LOOP_DEV}p2" "$BUILDDIR/mount_final/rootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not mount final rootfs" && EXITCODE=1
  [ $EXITCODE -ne 0 ] && umount_main_img
  return $EXITCODE
}

function shrink_main_img () {
  mount_main_img
  [ $? -ne 0 ] && FAIL_REASON="could not mount image" && EXITCODE=1
  [ $EXITCODE -ne 0 ] && umount_main_img && return $EXITCODE
  local image_name="kiosk_os.img"
  umount -f "$BUILDDIR/mount_final/bootfs" >/dev/null 2>&1
  umount -f "$BUILDDIR/mount_final/rootfs" >/dev/null 2>&1
  e2fsck -f -y "${LOOP_DEV}p2" >/dev/null 2>&1
  resize2fs -M "${LOOP_DEV}p2" >/dev/null 2>&1
  local part_start_sector=$(partx -g --nr 2 --output START "$BUILDDIR/images/${image_name}" 2>/dev/null | tr -d ' ')
  local fs_block_size=$(dumpe2fs -h "${LOOP_DEV}p2" 2>/dev/null | grep "Block size:" | awk '{print $3}')
  local fs_block_count=$(dumpe2fs -h "${LOOP_DEV}p2" 2>/dev/null | grep "Block count:" | awk '{print $3}')
  local fs_size_bytes=$(( fs_block_count * fs_block_size ))
  local buffer_bytes=$(( 10 * 1024 * 1024 ))
  local total_part2_bytes=$(( fs_size_bytes + buffer_bytes ))
  local part2_sectors=$(( total_part2_bytes / 512 ))
  local new_size_bytes=$(( (part_start_sector + part2_sectors) * 512 ))
  sfdisk --no-reread "$BUILDDIR/images/${image_name}" >/dev/null 2>&1 <<EOF
label-id: ${DISKID}
,1048576,c,*
${part_start_sector},${part2_sectors},83
EOF
  [ $? -ne 0 ] && FAIL_REASON="could not shrink partition" && EXITCODE=1
  umount_main_img
  [ $EXITCODE -ne 0 ] && return $EXITCODE
  truncate -s "${new_size_bytes}" "$BUILDDIR/images/${image_name}" >/dev/null 2>&1
  return $EXITCODE
}

function check_main_dev () {
  local main_dev="/dev/$DEVICE"
  local root_num="2"
  local boot_num="1"
  ROOT_DEV="${main_dev}${root_num}"
  BOOT_DEV="${main_dev}${boot_num}"
  if ! parted -ms "$main_dev" print >/dev/null 2>&1; then
    FAIL_REASON="$main_dev not found"
    EXITCODE=1 && return $EXITCODE
  fi
  if [ "$(blkid -o value -s LABEL $BOOT_DEV)" != "bootfs" ]; then
    FAIL_REASON="$BOOT_DEV label not match 'bootfs'"
    EXITCODE=1 && return $EXITCODE
  fi
  if [ "$(blkid -o value -s LABEL $ROOT_DEV)" != "rootfs" ]; then
    FAIL_REASON="$ROOT_DEV label not match 'rootfs'"
    EXITCODE=1 && return $EXITCODE
  fi
  fsck -a $BOOT_DEV >/dev/null 2>&1
  fsck -a $ROOT_DEV >/dev/null 2>&1
  e2fsck -f -y $ROOT_DEV >/dev/null 2>&1
  local part_table=$(parted -m "$main_dev" unit b print | tr -d 'B')
  local last_part_num=$(echo "$part_table" | tail -n 1 | cut -d ":" -f 1)
  if [ $root_num -ne $last_part_num ] ; then
    FAIL_REASON="$ROOT_DEV is not last partition!"
    EXITCODE=1 && return $EXITCODE
  fi
  return $EXITCODE
}

function umount_main_dev () {
  cool_down
  umount "$BUILDDIR/mount_sqfs/devel" >/dev/null 2>&1
  umount "$BUILDDIR/mount_sqfs/base" >/dev/null 2>&1
  cool_down
  umount $BOOT_DEV >/dev/null 2>&1
  umount $ROOT_DEV >/dev/null 2>&1
  sleep 2
  ROOT_DEV="NOT_MOUNTED"
  BOOT_DEV="NOT_MOUNTED"
  return 0
}

function mount_main_dev () {
  local main_dev="/dev/$DEVICE"
  local root_num="2"
  local boot_num="1"
  ROOT_DEV="${main_dev}${root_num}"
  BOOT_DEV="${main_dev}${boot_num}"
  umount_main_dev
  check_main_dev
  [ $EXITCODE -ne 0 ] && umount_main_dev && return $EXITCODE
  mount -o x-gvfs-hide -r $BOOT_DEV "$BUILDDIR/mount_bootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not mount bootfs" && EXITCODE=1
  mount -o x-gvfs-hide -r $ROOT_DEV "$BUILDDIR/mount_rootfs" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not mount rootfs" && EXITCODE=1
  [ $EXITCODE -ne 0 ] && umount_main_dev && return $EXITCODE
  if [ "$IMAGE_LOAD" != "ROOT" ]; then
    if ! mount -o x-gvfs-hide -r -t squashfs "$BUILDDIR/mount_rootfs/IMAGES/$(format_image_load)/system.sqfs" "$BUILDDIR/mount_sqfs/base" >/dev/null 2>&1; then
      FAIL_REASON="mount /IMAGES/$(format_image_load)/system.sqfs failed!\n"
      EXITCODE=1
    fi
    if [ $EXITCODE -eq 0 ] && [ -d "$BUILDDIR/mount_rootfs/DATA/${IMAGE_LOAD}/devel_data/data" ]; then
      sleep 2
      if ! mount -o x-gvfs-hide -r -t overlay overlay \
        -o lowerdir="$BUILDDIR/mount_sqfs/base/SYSTEM",upperdir="$BUILDDIR/mount_rootfs/DATA/${IMAGE_LOAD}/devel_data/data",workdir="$BUILDDIR/mount_rootfs/DATA/${IMAGE_LOAD}/devel_data/work" "$BUILDDIR/mount_sqfs/devel" >/dev/null 2>&1; then
        FAIL_REASON="mount developer data overlay failed!\n"
        EXITCODE=1
      fi
    fi
    sleep 2
  fi
  [ $EXITCODE -ne 0 ] && umount_main_dev
  return $EXITCODE
}

function gen_boot_folder () {
  ! ls "$BUILDDIR/mount_bootfs/"* >/dev/null 2>&1 && return 1
  rm -rf "$BUILDDIR/mount_final/bootfs/"* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/BOOT" >/dev/null 2>&1
  mkdir -p "$BUILDDIR/mount_final/rootfs/BOOT"
  cp -af "$BUILDDIR/mount_bootfs/initramfs"* "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_bootfs/kernel"*".img" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_bootfs/start"*".elf" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_bootfs/fixup"*".dat" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_bootfs/bootcode.bin" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_bootfs/bcm"*".dtb" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  cp -arf "$BUILDDIR/mount_bootfs/overlays" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  find "$BUILDDIR/mount_bootfs" -maxdepth 1 -mindepth 1 -exec cp -arf {} "$BUILDDIR/mount_final/bootfs" \;
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$BUILDDIR/mount_final/bootfs/config-initramfs.txt" | tee "$BUILDDIR/mount_final/bootfs/config-initramfs.txt" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_final/bootfs/config-initramfs.txt" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  echo '
##################################################
#       All changes to this file will be         #
#           reverted before boot!                #
#                                                #
#     please use config-custom.txt instead!      #
##################################################
' | cat - "$BUILDDIR/mount_final/bootfs/config.txt" | tee "$BUILDDIR/mount_final/bootfs/config.txt" >/dev/null 2>&1
  cp -af "$BUILDDIR/mount_final/bootfs/config.txt" "$BUILDDIR/mount_final/rootfs/BOOT/" >/dev/null 2>&1
  touch "$BUILDDIR/mount_final/bootfs/config-custom.txt" >/dev/null 2>&1
  return 0
}

function gen_system_folder () {
  local exitcode=0
  local base_sys="mount_rootfs"
  ls "$BUILDDIR/mount_sqfs/base/"* >/dev/null 2>&1 && base_sys="mount_sqfs/base"
  ls "$BUILDDIR/mount_sqfs/devel/"* >/dev/null 2>&1 && base_sys="mount_sqfs/devel"
  local imgldr_ver="$("$BUILDDIR/$base_sys/usr/bin/initramfs-imgldr" -v 2>/dev/null | perl -pe 'if(($v)=/([0-9]+([.][0-9]+)+)/){print"$v\n";exit}$_=""' 2>/dev/null)"
  ! compare_version "$imgldr_ver" "2.7" && echo "initramfs-imgldr is not installed on source or version is too old!\n" && exitcode=1 && return $exitcode
  rm -rf "$BUILDDIR/mount_final/rootfs/SYSTEM" >/dev/null 2>&1
  mkdir -p "$BUILDDIR/mount_final/rootfs/SYSTEM"
  find "$BUILDDIR/$base_sys" -maxdepth 1 -mindepth 1 -not -name 'SYSTEM' -not -name 'BOOT' -not -name 'INFO' -not -name 'IMAGES' -not -name 'CONFIG' -not -name 'DATA' -exec cp -arf {} "$BUILDDIR/mount_final/rootfs/SYSTEM" \;
  [ $? -ne 0 ] && echo "copy system files failed!\n" && exitcode=1 && return $exitcode
  for sysfolder in bin lib sbin; do
    if [ -d "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" ]; then
      mkdir -p "$BUILDDIR/mount_final/rootfs/SYSTEM/usr/$sysfolder"
      mv -f "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder/"* "$BUILDDIR/mount_final/rootfs/SYSTEM/usr/$sysfolder/" >/dev/null 2>&1
    fi
    rm -rf "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
    ln -s usr/$sysfolder "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
  done
  for sysfolder in etc home media mnt opt root srv tmp; do
    if [ -d "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" ]; then
      mkdir -p "$BUILDDIR/mount_final/rootfs/SYSTEM/var/kiosk/$sysfolder"
      mv -f "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder/"* "$BUILDDIR/mount_final/rootfs/SYSTEM/var/kiosk/$sysfolder/" >/dev/null 2>&1
    fi
    rm -rf "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
    ln -s var/kiosk/$sysfolder "$BUILDDIR/mount_final/rootfs/SYSTEM/$sysfolder" >/dev/null 2>&1
  done
  rm -rf "$BUILDDIR/mount_final/rootfs/System Volume Information" >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/.Trash-1000" >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/lost+found/."* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/lost+found/"* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/tmp/"* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/var/tmp/"* >/dev/null 2>&1
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/etc/machine-id" >/dev/null 2>&1
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/var/lib/dbus/machine-id" >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/ssh/ssh_host_"*"_key"* >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/var/lib/dhcp/"* >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/network/interfaces.d/"* >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/wpa_supplicant/wpa_supplicant"*".conf" >/dev/null 2>&1
  echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev" > "$BUILDDIR/mount_final/rootfs/etc/wpa_supplicant/wpa_supplicant.conf"
  echo "update_config=1" >> "$BUILDDIR/mount_final/rootfs/etc/wpa_supplicant/wpa_supplicant.conf"
  rm -f "$BUILDDIR/mount_final/rootfs/etc/NetworkManager/system-connections/sqfs_"*".nmconnection" >/dev/null 2>&1
  [ -f "$BUILDDIR/mount_final/rootfs/etc/dhcpcd.conf" ] && sed -i '/#___IMGLDR_CONFIG_BEGIN___/,/#___IMGLDR_CONFIG_END___/d' "$BUILDDIR/mount_final/rootfs/etc/dhcpcd.conf" >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/vnc-web/vncpasswd.pass" >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/timezone" >/dev/null 2>&1
  echo "UTC" > "$BUILDDIR/mount_final/rootfs/etc/timezone"
  rm -f "$BUILDDIR/mount_final/rootfs/etc/localtime" >/dev/null 2>&1
  ln -s /usr/share/zoneinfo/UTC "$BUILDDIR/mount_final/rootfs/etc/localtime"
  rm -f "$BUILDDIR/mount_final/rootfs/etc/console-setup/cached_"* >/dev/null 2>&1
  cat >"$BUILDDIR/mount_final/rootfs/etc/default/keyboard" <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"

EOF
  rm -f "$BUILDDIR/mount_final/rootfs/root/.bash_history" >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/root/.vnc" >/dev/null 2>&1
  local first_userid=$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $3; exit }' "$BUILDDIR/mount_final/rootfs/etc/passwd" 2>/dev/null)
  local first_username=$(awk -F: -v uid="$first_userid" '$3 == uid { print $1; exit }' "$BUILDDIR/mount_final/rootfs/etc/passwd" 2>/dev/null)
  local first_usergid=$(awk -F: -v uid="$first_userid" '$3 == uid { print $4; exit }' "$BUILDDIR/mount_final/rootfs/etc/passwd" 2>/dev/null)
  local first_usergname=$(awk -F: -v gid="$first_usergid" '$3 == gid { print $1; exit }' "$BUILDDIR/mount_final/rootfs/etc/group" 2>/dev/null)
  local first_userhome=$(awk -F: -v uid="$first_userid" '$3 == uid { print $6; exit }' "$BUILDDIR/mount_final/rootfs/etc/passwd" 2>/dev/null)
  if [ -n "$first_username" ]; then
    rm -rf "$BUILDDIR/mount_final/rootfs$first_userhome" >/dev/null 2>&1
    cp -arf "$BUILDDIR/mount_final/rootfs/etc/skel"/. "$BUILDDIR/mount_final/rootfs$first_userhome" >/dev/null 2>&1
    chown -R ${first_userid}:${first_usergid} "$BUILDDIR/mount_final/rootfs$first_userhome" >/dev/null 2>&1
  fi
  rm -f "$BUILDDIR/mount_final/rootfs/etc/cockpit/ws-certs.d/"* >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/nginx/sites-enabled/vnc-web" >/dev/null 2>&1
  rm -f "$BUILDDIR/mount_final/rootfs/etc/vnc-web/"* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/var/log/journal/"* >/dev/null 2>&1
  find "$BUILDDIR/mount_final/rootfs/var/log/" -type f -name "*.log" -exec truncate -s 0 {} + >/dev/null 2>&1
  find "$BUILDDIR/mount_final/rootfs/var/log/" -type f -name "*.[0-9]" -delete >/dev/null 2>&1
  find "$BUILDDIR/mount_final/rootfs/var/log/" -type f -name "*.gz" -delete >/dev/null 2>&1
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/var/log/dmesg" 2>/dev/null
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/var/log/wtmp" 2>/dev/null
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/var/log/lastlog" 2>/dev/null
  truncate -s 0 "$BUILDDIR/mount_final/rootfs/var/log/btmp" 2>/dev/null
  rm -rf "$BUILDDIR/mount_final/rootfs/var/cache/apt/archives/"* 2>/dev/null
  rm -rf "$BUILDDIR/mount_final/rootfs/var/lib/apt/lists/"* 2>/dev/null
  #sed -i "s/127\.0\.1\.1.*$(<"$BUILDDIR/mount_final/rootfs/etc/hostname")/127.0.1.1\traspi/g" "$BUILDDIR/mount_final/rootfs/etc/hosts"
  sed -i "s/^127.0.1.1.*/127.0.1.1\traspi/" "$BUILDDIR/mount_final/rootfs/etc/hosts" >/dev/null 2>&1
  echo "raspi" > "$BUILDDIR/mount_final/rootfs/etc/hostname"
  if -f "$BUILDDIR/mount_final/rootfs/etc/default/crda" 2>/dev/null; then
      sed -i "s/^REGDOMAIN=.*$/REGDOMAIN=/" "$BUILDDIR/mount_final/rootfs/etc/default/crda" >/dev/null 2>&1
  fi
  if grep -q "WirelessEnabled=true" "$BUILDDIR/mount_final/rootfs/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null; then
    sed -i 's/^WirelessEnabled=.*/WirelessEnabled=false/' "$BUILDDIR/mount_final/rootfs/var/lib/NetworkManager/NetworkManager.state" >/dev/null 2>&1
  fi
  local filename
  for filename in "$BUILDDIR/mount_final/rootfs/var/lib/systemd/rfkill/"*:wlan ; do
    echo 1 > "$filename"
  done
  return $exitcode
}

function gen_info_folder () {
  rm -rf "$BUILDDIR/mount_final/rootfs/INFO" >/dev/null 2>&1
  mkdir -p "$BUILDDIR/mount_final/rootfs/INFO"
  cat >"$BUILDDIR/mount_final/rootfs/INFO/systeminfo" <<EOF
system=${BRANCH}
version=${VERSION}
update=${SERVER}
EOF
  chmod -f u=r,g=r,o=r "$BUILDDIR/mount_final/rootfs/INFO/systeminfo"
  if ls "$SCRIPTDIR/scripts/"* >/dev/null 2>&1; then
    ( cd "$SCRIPTDIR/scripts" && tar -cf "$BUILDDIR/mount_final/rootfs/INFO/scripts.tar" * >/dev/null 2>&1)
    [ ! -f "$BUILDDIR/mount_final/rootfs/INFO/scripts.tar" ] && echo "create INFO/scripts.tar failed!" && return 1
  fi
  return 0
}

function gen_system_image () {
  local result
  result=$(gen_boot_folder)
  [ "$result" != "" ] && FAIL_REASON="$result" && EXITCODE=1 && return $EXITCODE
  result=$(gen_system_folder)
  [ "$result" != "" ] && FAIL_REASON="$result" && EXITCODE=1 && return $EXITCODE
  result=$(gen_info_folder)
  [ "$result" != "" ] && FAIL_REASON="$result" && EXITCODE=1 && return $EXITCODE
  find "$BUILDDIR/mount_final/rootfs" -maxdepth 1 -mindepth 1 -not -name 'SYSTEM' -not -name 'BOOT' -not -name 'INFO' -exec rm -rf {} \;
  mksquashfs "$BUILDDIR/mount_final/rootfs" "$BUILDDIR/images/system.sqfs" >/dev/null 2>&1
  [ $? -ne 0 ] && FAIL_REASON="could not create system.sqfs" && EXITCODE=1 && return $EXITCODE
  set_base_perms "$BUILDDIR/images"
  return 0
}

function gen_main_image () {
  local base_sys="mount_rootfs"
  ls "$BUILDDIR/mount_sqfs/base/"* >/dev/null 2>&1 && base_sys="mount_sqfs/base"
  ls "$BUILDDIR/mount_sqfs/devel/"* >/dev/null 2>&1 && base_sys="mount_sqfs/devel"
  local default_target="multi-user.target"
  if [ -e "$BUILDDIR/$base_sys/usr/lib/systemd/system/default.target" ]; then
    default_target="$(readlink -f "$BUILDDIR/$base_sys/usr/lib/systemd/system/default.target")"
    default_target="$(basename "$default_target")"
  fi
  echo "console=tty1 root=PARTUUID=${DISKID}-02 rootfstype=ext4 fsck.repair=yes rootwait FIRSTBOOT fastboot logo.nologo loglevel=3" > "$BUILDDIR/mount_final/bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
  if [ "$default_target" == "graphical.target" ]; then
    sed -i 's/$/ vt.global_cursor_default=0/g' "$BUILDDIR/mount_final/bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ splash/g' "$BUILDDIR/mount_final/bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
    sed -i 's/$/ quiet/g' "$BUILDDIR/mount_final/bootfs/cmdline.txt" || echo "boot: write cmdline failed!"
  fi
  rm -rf "$BUILDDIR/mount_final/rootfs/."* >/dev/null 2>&1
  rm -rf "$BUILDDIR/mount_final/rootfs/"* >/dev/null 2>&1
  mkdir "$BUILDDIR/mount_final/rootfs/CONFIG" "$BUILDDIR/mount_final/rootfs/IMAGES" "$BUILDDIR/mount_final/rootfs/DATA/BASE_IMAGE/config" >/dev/null 2>&1
  cp -f "$BUILDDIR/images/system.sqfs" "$BUILDDIR/mount_final/rootfs/IMAGES/system.sqfs" >/dev/null 2>&1
  echo "BASE_IMAGE" > "$BUILDDIR/mount_final/rootfs/CONFIG/image_load" || echo "root: write image_load file failed!"
  echo "true" > "$BUILDDIR/mount_final/rootfs/CONFIG/auto_cleanup" || echo "root: write auto_cleanup file failed!"
  echo "RAMDISK" > "$BUILDDIR/mount_final/rootfs/DATA/BASE_IMAGE/config/mode" || echo "root: write mode file failed!"
  echo "NONE" > "$BUILDDIR/mount_final/rootfs/DATA/BASE_IMAGE/config/reset" || echo "root: write reset file failed!"
  return 0
}

function build_release_folder () {
  mv -f "$BUILDDIR/images/kiosk_os.img" "$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.img"
  mv -f "$BUILDDIR/images/system.sqfs" "$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.system.sqfs"
  cat >"$RELEASEDIR/kiosk-os_${BRANCH}-v${VERSION}.update.conf" <<EOF
system=${BRANCH}
version=${VERSION}
download={DOWNLOAD_LINK}
checksum={SHA512SUM}
EOF
  set_base_perms "$RELEASEDIR"
}

function cmd_run() {
  function umount_all () {
    umount_main_dev
    umount_main_img
  }
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
  infobox "Check device $DEVICE... "
  check_main_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Create main image container... "
  create_main_img || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Mount main image container... "
  mount_main_img || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Mount device $DEVICE... "
  mount_main_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Generate system.sqfs... "
  gen_system_image || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Generate main image... "
  gen_main_image || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "umount build dirs... "
  umount_all
  infobox "Finalize main image... "
  shrink_main_img || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Build Release... "
  build_release_folder || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
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
  check_main_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  [ $EXITCODE -ne 0 ] && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Mount device $DEVICE... "
  local temp_IMAGE_LOAD="$IMAGE_LOAD"
  IMAGE_LOAD="ROOT"
  mount_main_dev || echo "$FAIL_REASON" >> "$LOGFILE"
  IMAGE_LOAD="$temp_IMAGE_LOAD"
  [ $EXITCODE -ne 0 ] && umount_all && msgbox "$FAIL_REASON" && return $EXITCODE
  infobox "Copy files..."
  if ls "$SCRIPTDIR/$BASE_BOOT/"* >/dev/null 2>&1; then
    set_base_perms "$SCRIPTDIR/$BASE_BOOT"
    cd $SCRIPTDIR/$BASE_BOOT >/dev/null 2>&1
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$BUILDDIR/mount_bootfs" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_BOOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1; then
    set_base_perms "$SCRIPTDIR/$BASE_ROOT"
    cd $SCRIPTDIR/$BASE_ROOT >/dev/null 2>&1
    find . -mindepth 1 -type f -exec cp --preserve=mode --parents -f {} "$BUILDDIR/mount_rootfs" \;
    [ $? -ne 0 ] && result="Copy files failed!\n{SCRIPT_DIR}/$BASE_ROOT"
    cd "$SCRIPTDIR" >/dev/null 2>&1
  fi
  if [ -f "$BUILDDIR/mount_rootfs/IMAGES/$(format_image_load)/system.sqfs" ]; then
    echo "DEVELOPER" > "$BUILDDIR/mount_rootfs/DATA/${IMAGE_LOAD}/config/mode"
  fi
  umount_main_dev >/dev/null 2>&1
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
  local menu_image_root
  local menu_image_base
  local menu_image_custom
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
    [ -z "$IMAGE_LOAD" ] && IMAGE_LOAD="ROOT"
    ( [ -z "$BASE_BOOT" ] || [ "$BASE_BOOT" == "." ] || [ "$BASE_BOOT" == "/." ] ) && BASE_BOOT="base/bootfs"
    ( [ -z "$BASE_ROOT" ] || [ "$BASE_ROOT" == "." ] || [ "$BASE_ROOT" == "/." ] ) && BASE_ROOT="base/rootfs"
    [ -n "$DEVICE" ] && [ -n "$BRANCH" ] && [ -n "$VERSION" ] && start_runable="START" || start_runable="N/A"
    [ -n "$DEVICE" ] && ( ls "$SCRIPTDIR/$BASE_BOOT/"* >/dev/null 2>&1 || ls "$SCRIPTDIR/$BASE_ROOT/"* >/dev/null 2>&1 ) && base_runable="BASEFILES" || base_runable="N/A"
    menu_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" \
      --menu "" \
      $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) $(( $bash_lines - 14 )) \
      "DEVICE  " "$device" \
      "BRANCH  " "$branch" \
      "VERSION  " "$version" \
      "SERVER  " "$server" \
      "BASE_BOOT  " "$BASE_BOOT" \
      "BASE_ROOT  " "$BASE_ROOT" \
      "IMAGE_LOAD  " "$IMAGE_LOAD" \
      "  " "" \
      "$start_runable  " "start creating images" \
      "$base_runable  " "copy basefiles to disk" 3>&1 1>&2 2>&3)
    case $menu_sel in
      "  ")
        #
      ;;
      "DEVICE  ")
        disklist=$(get_disklist)
        if [ "${disklist}" != "" ]; then
          menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --radiolist \
            "Choose disk:" \
            $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) $(( $bash_lines - 14 )) \
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
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
          "$BRANCH" 3>&1 1>&2 2>&3)
        BRANCH=$menu_sub_sel
      ;;
      "VERSION  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input VERSION:" \
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
          "$VERSION" 3>&1 1>&2 2>&3)
        VERSION=$menu_sub_sel
      ;;
      "SERVER  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input SERVER:" \
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
          "$SERVER" 3>&1 1>&2 2>&3)
        SERVER=$menu_sub_sel
      ;;
      "BASE_BOOT  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input BASE_BOOT:" \
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
          "$BASE_BOOT" 3>&1 1>&2 2>&3)
        BASE_BOOT=$menu_sub_sel
      ;;
      "BASE_ROOT  ")
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
          "Input BASE_ROOT:" \
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
          "$BASE_ROOT" 3>&1 1>&2 2>&3)
        BASE_ROOT=$menu_sub_sel
      ;;
      "IMAGE_LOAD  ")
        [ "$IMAGE_LOAD" == "ROOT" ] && menu_image_root="ON" || menu_image_root="OFF"
        [ "$IMAGE_LOAD" == "BASE_IMAGE" ] && menu_image_base="ON" || menu_image_base="OFF"
        ( [ "$IMAGE_LOAD" != "ROOT" ] && [ "$IMAGE_LOAD" != "BASE_IMAGE" ] ) && menu_image_custom="ON" || menu_image_custom="OFF"
        menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --radiolist \
          "Select image to load:" \
          $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) $(( $bash_lines - 14 )) \
          "ROOT" "rootfs" "$menu_image_root" \
          "BASE_IMAGE" "rootfs/IMAGES/system.sqfs" "$menu_image_base" \
          "CUSTOM" "rootfs/IMAGES/{CUSTOM}/system.sqfs" "$menu_image_custom" 3>&1 1>&2 2>&3)
        if [ "$menu_sub_sel" == "CUSTOM" ]; then
          menu_sub_sel=$(whiptail --title "$SCRIPT_TITLE - v$SCRIPT_VERSION $menu_title" --inputbox \
            "Input image name:" \
            $(( $bash_lines - 7 )) $(( $bash_columns - 8 )) \
            "" 3>&1 1>&2 2>&3)
        fi
        IMAGE_LOAD=$menu_sub_sel
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
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "MENU" ]] && cmd_menu

exit $EXITCODE
