#!/bin/bash
##############################################
##                                          ##
##  kiosk-os                                ##
##                                          ##
##############################################

#get some variables
SCRIPT_TITLE="kiosk-os"
SCRIPT_VERSION="1.4"
SCRIPTDIR="$(readlink -f "$0")"
SCRIPTNAME="$(basename "$SCRIPTDIR")"
SCRIPTDIR="$(dirname "$SCRIPTDIR")"
PIDFILE="/run/kiosk-os.pid"
EXITCODE=0

#!!!RUN RESTRICTIONS!!!
#only for raspberry pi (rpi5|rpi4|rpi3|all) can combined!
raspi="all"
#only for Raspbian OS (bookworm|bullseye|all) can combined!
rasos="bookworm|bullseye"
#only for cpu architecture (i386|armhf|amd64|arm64) can combined!
cpuarch=""
#only for os architecture (32|64) can NOT combined!
bsarch=""
#this aptpaks need to be installed!
aptpaks=( wget curl )

#check commands
for i in "$@"
do
  case $i in
    --BRANCH=*)
    U_BRANCH=(${i#--BRANCH=})
    shift # past argument
    ;;
    --SERVER=*)
    U_SERVER=(${i#--SERVER=})
    shift # past argument
    ;;
    -c|--update_check)
    [ "$CMD" == "" ] && CMD="update_check" || CMD="help"
    shift # past argument
    ;;
    -d|--update_download)
    [ "$CMD" == "" ] && CMD="update_download" || CMD="help"
    shift # past argument
    ;;
    -f|--force_download)
    [ "$CMD" == "" ] && CMD="force_download" || CMD="help"
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
[ "$CMD" == "" ] && CMD="help"

function do_check_start() {
  #check if superuser
  if [ $UID -ne 0 ]; then
    echo "Please run this script with Superuser privileges!"
    exit 1
  fi
  #check if updater is already running or create pidfile if needed
  if [[ "$CMD" == "update_download" ]] && [ -e "$PIDFILE" ] && ps -p $(<"$PIDFILE") >/dev/null 2>&1; then
    echo "Updater is already running (PID:$(<"$PIDFILE"))!"
    exit 1
  elif [ "$CMD" == "update_download" ]; then
    echo $$ > "$PIDFILE"
  fi
  #check if raspberry pi 
  if [ "$raspi" != "" ]; then
    raspi_v="$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)"
    local raspi_res="false"
    [[ "$raspi_v" =~ "Raspberry Pi" ]] && [[ "$raspi" =~ "all" ]] && raspi_res="true"
    [[ "$raspi_v" =~ "Raspberry Pi 3" ]] && [[ "$raspi" =~ "rpi3" ]] && raspi_res="true"
    [[ "$raspi_v" =~ "Raspberry Pi 4" ]] && [[ "$raspi" =~ "rpi4" ]] && raspi_res="true"
    [[ "$raspi_v" =~ "Raspberry Pi 5" ]] && [[ "$raspi" =~ "rpi5" ]] && raspi_res="true"
    if [ "$raspi_res" == "false" ]; then
      echo "This Device seems not to be an Raspberry Pi ($raspi)! Can not continue with this script!"
      exit 1
    fi
  fi
  #check if raspbian
  if [ "$rasos" != "" ]
  then
    rasos_v="$(lsb_release -d -s 2>/dev/null)"
    [ -f /etc/rpi-issue ] && rasos_v="Raspbian ${rasos_v}"
    local rasos_res="false"
    [[ "$rasos_v" =~ "Raspbian" ]] && [[ "$rasos" =~ "all" ]] && rasos_res="true"
    [[ "$rasos_v" =~ "Raspbian" ]] && [[ "$rasos_v" =~ "bullseye" ]] && [[ "$rasos" =~ "bullseye" ]] && rasos_res="true"
    [[ "$rasos_v" =~ "Raspbian" ]] && [[ "$rasos_v" =~ "bookworm" ]] && [[ "$rasos" =~ "bookworm" ]] && rasos_res="true"
    if [ "$rasos_res" == "false" ]; then
      echo "You need to run Raspbian OS ($rasos) to run this script! Can not continue with this script!"
      exit 1
    fi
  fi
  #check cpu architecture
  if [ "$cpuarch" != "" ]; then
    cpuarch_v="$(dpkg --print-architecture 2>/dev/null)"
    if [[ ! "$cpuarch" =~ "$cpuarch_v" ]]; then
      echo "Your CPU Architecture ($cpuarch_v) is not supported! Can not continue with this script!"
      exit 1
    fi
  fi
  #check os architecture
  if [ "$bsarch" == "32" ] || [ "$bsarch" == "64" ]; then
    bsarch_v="$(getconf LONG_BIT 2>/dev/null)"
    if [ "$bsarch" != "$bsarch_v" ]; then
      echo "Your OS Architecture ($bsarch_v) is not supported! Can not continue with this script!"
      exit 1
    fi
  fi
  #check apt paks
  local apt
  local apt_res
  IFS=$' '
  if [ "${#aptpaks[@]}" != "0" ]; then
    for apt in ${aptpaks[@]}; do
      [[ ! "$(dpkg -s $apt 2>/dev/null)" =~ "Status: install" ]] && apt_res="${apt_res}${apt}, "
    done
    if [ "$apt_res" != "" ]; then
      echo "Not installed apt paks: ${apt_res%?%?}! Can not continue with this script!"
      exit 1
    fi
  fi
  unset IFS
  #boot partition mount
  if [ "$(findmnt -n -o FSTYPE /boot 2>/dev/null)" == "vfat" ]; then
    BOOTDIR=/boot
  elif [ "$(findmnt -n -o FSTYPE /boot/firmware 2>/dev/null)" == "vfat" ]; then
    BOOTDIR=/boot/firmware
  else
    echo "Could not find bootpartition! exit."
    exit 1
  fi
  #bootro state
  if findmnt -n -o OPTIONS $BOOTDIR | egrep "^ro,|,ro,|,ro$" &>/dev/null; then
    boot_ro="true"
  else
    boot_ro="false"
  fi
  #get script states
  [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" != "overlay" ] && noOverlay=y
  grep SETUPMODE $BOOTDIR/cmdline.txt >/dev/null 2>&1 && SETUPMODE=y
  grep SAVEDBOOT $BOOTDIR/cmdline.txt >/dev/null 2>&1 && SAVEDBOOT=y
  grep boot=image $BOOTDIR/cmdline.txt >/dev/null 2>&1 || noOverlay=y
}

function compare_version(){ # installed_version, update_version -> 0 = update_version is newer 1 = update_version is same or older
  IFS=.
  local ver1=($1)
  local ver2=($2)
  local retcode=1
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
      retcode=0
    fi
  done
  unset IFS
  return $retcode
}

function config_read(){ # path, key, defaultvalue -> value
  local val=$( (grep -E "^${2}=" -m 1 "${1}" 2>/dev/null || echo "VAR=__UNDEFINED__") | head -n 1 | cut -d '=' -f 2-)
  #val=$(echo "${val}" | sed 's/ *$//g' | sed 's/^ *//g')
  val=$(echo "$val" | xargs)
  [ "${val}" == "__UNDEFINED__" ] || [ "${val}" == "" ] && val="$3"
  printf -- "%s" "${val}"
}

function config_read_info(){
  BRANCH_SYS="$(awk 'NR==1 {print $1}' /etc/imageinfo/sysinfo 2>/dev/null)"
  [ "$BRANCH_SYS" == "" ] && BRANCH_SYS="NONE"
  VERSION_SYS="$(awk 'NR==1 {print $2}' /etc/imageinfo/sysinfo 2>/dev/null)"
  [ "$VERSION_SYS" == "" ] && VERSION_SYS="0"
  BRANCH_OEM="$(awk 'NR==1 {print $1}' /etc/imageinfo/oeminfo 2>/dev/null)"
  [ "$BRANCH_OEM" == "" ] && BRANCH_OEM="NONE"
  VERSION_OEM="$(awk 'NR==1 {print $2}' /etc/imageinfo/oeminfo 2>/dev/null)"
  [ "$VERSION_OEM" == "" ] && VERSION_OEM="0"
  [ "$U_BRANCH" != "" ] && BRANCH_OEM="$U_BRANCH" && VERSION_OEM="0"
  [ "$BRANCH_OEM" == "NONE" ] && BRANCH_OEM="$BRANCH_SYS" && BRANCH_SYS="NONE" && VERSION_OEM="$VERSION_SYS" && VERSION_SYS="0"
  UPDATESERVER="NONE"
  local t_updateserver="$(awk 'NR==1 {print $1}' /etc/imageinfo/updateserver 2>/dev/null)"
  [ "$U_SERVER" != "" ] && t_updateserver="$U_SERVER"
  [ "$t_updateserver" != "" ] && UPDATESERVER="$t_updateserver"
}

function config_read_update(){
  VERSION_SRV=$(config_read "/tmp/srv_image_data" upd_version "0")
  BRANCH_SRV=$(config_read "/tmp/srv_image_data" upd_branch NONE)
  DOWNLOAD_SRV=$(config_read "/tmp/srv_image_data" upd_download NONE)
  CHECKSUM_SRV=$(config_read "/tmp/srv_image_data" upd_checksum NONE)
  SYS_VERSION_SRV=$(config_read "/tmp/srv_image_data" upd_sys_version "0")
  SYS_BRANCH_SRV=$(config_read "/tmp/srv_image_data" upd_sys_branch NONE)
  SYS_DOWNLOAD_SRV=$(config_read "/tmp/srv_image_data" upd_sys_download NONE)
  SYS_CHECKSUM_SRV=$(config_read "/tmp/srv_image_data" upd_sys_checksum NONE)
  local script_start=$(awk '/^___INSTALL_SCRIPT_BEGIN___/ { print NR + 1; exit 0; }' /tmp/srv_image_data 2>/dev/null)
  local script_end=$(awk '/^___INSTALL_SCRIPT_END___/ { print NR - 1; exit 0; }' /tmp/srv_image_data 2>/dev/null)
  INSTALL_SCRIPT_SRV=$(head -n +${script_end} /tmp/srv_image_data 2>/dev/null | tail -n +${script_start} 2>/dev/null)
}

function cmd_update_check() {
  local retcode=1
  local server_config="${UPDATESERVER}${BRANCH_OEM}.config"
  OEM_UPDATE="FALSE"
  SYS_UPDATE="FALSE"
  rm -f "/tmp/srv_image_data" >/dev/null 2>&1
  if [ "$UPDATESERVER" == "NONE" ]; then
    echo "Could not check for update (no-updateserver)"
    EXITCODE=1
  elif [ "$BRANCH_OEM" == "NONE" ]; then
    echo "Could not check for update (no-branch)"
    EXITCODE=1
  elif [ "$noOverlay" != "" ]; then
    echo "Could not check for update (not overlay-mode)"
    EXITCODE=1
  else
    echo "check for updates..."
    wget -O "/tmp/srv_image_data" "$server_config" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      sed -i 's/\r$//g' "/tmp/srv_image_data" >/dev/null 2>&1
      config_read_update
      compare_version "$VERSION_OEM" "$VERSION_SRV" && OEM_UPDATE="TRUE"
      [ "$BRANCH_OEM" != "$BRANCH_SRV" ] && OEM_UPDATE="TRUE"
      [ "$SYS_BRANCH_SRV" != "NONE" ] && compare_version "$VERSION_SYS" "$SYS_VERSION_SRV" && SYS_UPDATE="TRUE"
      [ "$SYS_BRANCH_SRV" != "NONE" ] && [ "$BRANCH_SYS" != "$SYS_BRANCH_SRV" ] && SYS_UPDATE="TRUE"
      [ "$SYS_BRANCH_SRV" == "NONE" ] && [ "$BRANCH_SYS" != "NONE" ] && OEM_UPDATE="TRUE"
      [ "$CMD" == "force_download" ] && OEM_UPDATE="TRUE"
      [ "$CMD" == "force_download" ] && [ "$SYS_BRANCH_SRV" != "NONE" ] && SYS_UPDATE="TRUE"
      [ "$SYS_UPDATE" == "TRUE" ] && OEM_UPDATE="TRUE"
      [ "$OEM_UPDATE" == "TRUE" ] && retcode=0
      if [ "$BRANCH_SYS" == "NONE" ]; then
        echo "Installed  : ${BRANCH_OEM}-v${VERSION_OEM}"
      else
        echo "Installed  : ${BRANCH_OEM}-v${VERSION_OEM} (${BRANCH_SYS}-v${VERSION_SYS})"
      fi
      if [ "$SYS_BRANCH_SRV" == "NONE" ]; then
        echo "Server     : ${BRANCH_SRV}-v${VERSION_SRV}"
      else
        echo "Server     : ${BRANCH_SRV}-v${VERSION_SRV} (${SYS_BRANCH_SRV}-v${SYS_VERSION_SRV})"
      fi
      [ "$BRANCH_SRV" == "NONE" ] && retcode=2
      [ "$DOWNLOAD_SRV" == "NONE" ] && retcode=2
      [ "$CHECKSUM_SRV" == "NONE" ] && retcode=2
      if [ "$SYS_BRANCH_SRV" != "NONE" ]; then
        [ "$SYS_DOWNLOAD_SRV" == "NONE" ] && retcode=2
        [ "$SYS_CHECKSUM_SRV" == "NONE" ] && retcode=2
      fi
      [ $retcode -eq 0 ] && [[ ! "$CMD" =~ "_download" ]] && echo "You can start Update."
      [ $retcode -eq 1 ] && echo "Newest version already installed."
      [ $retcode -eq 2 ] && echo "Update check failed (server-config-error)" && EXITCODE=1
    else
      echo "Update check failed (server-error)"
      EXITCODE=1
    fi
  fi
  rm -f "/tmp/srv_image_data" >/dev/null 2>&1
  return $retcode
}

function cmd_update_download() {
  rm -rf /IMAGES/update >/dev/null 2>&1
  rm -rf /IMAGES/update_tmp >/dev/null 2>&1
  local filepath
  local chksum_cal
  local chksum_sav
  if cmd_update_check; then
    if [ "$SETUPMODE" != "" ] || [ "$SAVEDBOOT" != "" ]; then
      local response="x"
      echo "Updating the system image(s) will end SETUPMODE and SAVEDBOOT mode!"
      echo "Your saved data will be removed and mode changed to normal state."
      echo "Are you sure you want to continue?"
      echo "yes? (y), no? (n)"
      while [ "${response}" != "y" ] && [ "${response}" != "n" ]; do
        read -n 1 -s response
      done
      if [ "$response" == "n" ]; then
        echo "Update aborted by user."
        return 0
      else
        [ "$boot_ro" == "true" ] && mount -o remount,rw $BOOTDIR
        sed -i 's|SAVEDBOOT[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt
        sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
        sed -i 's|SETUPMODE[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt
        sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
        [ "$boot_ro" == "true" ] && mount -o remount,ro $BOOTDIR
      fi
    fi
    mkdir -p /IMAGES/update_tmp >/dev/null 2>&1
    echo "downloading update (this could take a while) ..."
    if [ "$OEM_UPDATE" == "TRUE" ]; then
      wget -O "/IMAGES/update_tmp/main.zip" "$DOWNLOAD_SRV" >/dev/null 2>&1
      chksum_cal=$(sha512sum '/IMAGES/update_tmp/main.zip' | awk 'NR==1 {print $1}')
      if [ "$CHECKSUM_SRV" != "$chksum_cal" ]; then
        rm -rf /IMAGES/update_tmp >/dev/null 2>&1
        echo "Download update failed (MAIN_IMG_checksum-error)"
        EXITCODE=1
      fi
    fi
    if [ $EXITCODE -eq 0 ] && [ "$SYS_UPDATE" == "TRUE" ]; then
      wget -O "/IMAGES/update_tmp/base.zip" "$SYS_DOWNLOAD_SRV" >/dev/null 2>&1
      chksum_cal=$(sha512sum '/IMAGES/update_tmp/base.zip' | awk 'NR==1 {print $1}')
      if [ "$SYS_CHECKSUM_SRV" != "$chksum_cal" ]; then
        rm -rf /IMAGES/update_tmp >/dev/null 2>&1
        echo "Download update failed (BASE_IMG_checksum-error)"
        EXITCODE=1
      fi
    fi
    if [ $EXITCODE -eq 0 ] && [ "$OEM_UPDATE" == "TRUE" ]; then
      echo "unpacking update (main image) (this could take a while) ..."
      unzip -qqo /IMAGES/update_tmp/main.zip -d /IMAGES/update_tmp
      if [ $? -ne 0 ]; then
        rm -rf /IMAGES/update_tmp >/dev/null 2>&1
        echo "Download update failed (MAIN_IMG_unpack-error)"
        EXITCODE=1
      else
        rm -f /IMAGES/update_tmp/main.zip
      fi
    fi
    if [ $EXITCODE -eq 0 ] && [ "$SYS_UPDATE" == "TRUE" ]; then
      echo "unpacking update (base image) (this could take a while) ..."
      unzip -qqo /IMAGES/update_tmp/base.zip -d /IMAGES/update_tmp
      if [ $? -ne 0 ]; then
        rm -rf /IMAGES/update_tmp >/dev/null 2>&1
        echo "Download update failed (BASE_IMG_unpack-error)"
        EXITCODE=1
      else
        rm -f /IMAGES/update_tmp/base.zip
      fi
    fi
    if [ $EXITCODE -eq 0 ]; then
      for filepath in /IMAGES/update_tmp/*; do
        if [ -f "${filepath}" ] && [ -f "${filepath}.sha512" ] && [ $EXITCODE -eq 0 ]; then
          chksum_cal=$(sha512sum "${filepath}" | awk 'NR==1 {print $1}')
          chksum_sav=$(awk 'NR==1 {print $1}' ${filepath}.sha512 2>/dev/null)
          rm -f "${filepath}.sha512"
          if [ "$chksum_sav" != "$chksum_cal" ]; then
            echo "Unpack update failed (file_checksum-error)"
            EXITCODE=1
          fi
        fi
      done
    fi
    if [ $EXITCODE -eq 0 ]; then
      mv -f /IMAGES/update_tmp /IMAGES/update
      if [ "$INSTALL_SCRIPT_SRV" != "" ]; then
        echo "$INSTALL_SCRIPT_SRV" > /IMAGES/update/install_update
      fi
      echo "Update downloaded successfully. Please reboot to install."
    else
      rm -rf /IMAGES/update_tmp >/dev/null 2>&1
    fi
  fi
  return $EXITCODE
}

function cmd_print_version() {
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
}

function cmd_print_help() {
  echo "Usage: $SCRIPTNAME [OPTION]"
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
  echo " "
  if [ "$BRANCH_SYS" == "NONE" ]; then
    echo "Current SYS Image: ${BRANCH_OEM}-v${VERSION_OEM}"
    echo "Current OEM Image: not installed!"
  else
    echo "Current SYS Image: ${BRANCH_SYS}-v${VERSION_SYS}"
    echo "Current OEM Image: ${BRANCH_OEM}-v${VERSION_OEM}"
  fi
  echo " "
  echo "--SERVER={VALUE}        change the update server temporarily"
  echo "--BRANCH={VALUE}        change the branch temporarily"
  echo "-c, --update_check      check for updates and print result"
  echo "-d, --update_download   check for updates and download it"
  echo "-f, --force_download    ignore version and download update"
  echo "-v, --version           print version info and exit"
  echo "-h, --help              print this help and exit"
  echo " "
  echo "Only one option at same time is allowed!"
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

if [ "$CMD" != "version" ] && [ "$CMD" != "help" ]; then
  do_check_start
fi
config_read_info
[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "update_check" ]] && cmd_update_check
[[ "$CMD" == "update_download" ]] && cmd_update_download
[[ "$CMD" == "force_download" ]] && cmd_update_download

exit $EXITCODE
