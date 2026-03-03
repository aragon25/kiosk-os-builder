#!/bin/bash
##############################################
##                                          ##
##  kiosk-os-configurator                   ##
##                                          ##
##############################################

#get some variables
export LC_ALL=C
export LANG=C
SCRIPT_TITLE="kiosk-os-configurator"
SCRIPT_VERSION="1.5"
SCRIPTDIR="$(readlink -f "$0")"
SCRIPTNAME="$(basename "$SCRIPTDIR")"
SCRIPTDIR="$(dirname "$SCRIPTDIR")"
FIRSTUSER=$(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" { print $1; exit }')
[ "$FIRSTUSER" != "" ] && FIRSTUSERGROUP=$(groups $FIRSTUSER | awk '{print $3}') || FIRSTUSERGROUP="__EMPTY__"
[ "$FIRSTUSER" != "" ] && FIRSTUSERHOME=$(getent passwd $FIRSTUSER | cut -d: -f6) || FIRSTUSERHOME="/home/__EMPTY__"
BOOTDIR=/boot
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
aptpaks=( rfkill )

#check commands
case $1 in
  --generate_README)
  CMD="generate_README"
  shift # past argument
  ;;
  --cleanup_image)
  CMD="cleanup_image"
  shift # past argument
  ;;
  --service)
  CMD="service"
  shift # past argument
  ;;
  --preserv)
  CMD="preserv"
  shift # past argument
  ;;
  -r|--RESET_ALL)
  CMD="RESET_ALL"
  shift # past argument
  ;;
  -R|--RESET_OFS)
  CMD="RESET_OFS"
  shift # past argument
  ;;
  -v|--version)
  CMD="version"
  shift # past argument
  ;;
  -h|--help)
  CMD="help"
  shift # past argument
  ;;
  *)
  if [ "$1" != "" ]
  then
    echo "Unknown option: $1"
    exit 1
  fi
  ;;
esac
if [ "$2" != "" ] 
then
  echo "Only one option at same time is allowed!"
  exit 1
fi
[ "$CMD" == "" ] && CMD="help"

function do_check_start() {
  #check if superuser
  if [ $UID -ne 0 ]; then
    echo "Please run this script with Superuser privileges!"
    exit 1
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
  [ -f "/run/${SCRIPT_TITLE}.lock" ]  && islocked=y
}

function set_boot_rw() {
  [ "$boot_ro" == "true" ] && mount -o remount,rw $BOOTDIR
}

function set_boot_ro() {
  [ "$boot_ro" == "true" ] && mount -o remount,ro $BOOTDIR
}

function set_base_perms() {
  local filetype
  local entry
  local test
  IFS=$'\n'
  test=($(find "$1"))
  if [ "${#test[@]}" != "0" ]; then
    for entry in ${test[@]}; do
      chown -f 0:0 "$entry" >/dev/null 2>&1
      if [ -f "$entry" ]; then
        filetype=$(file -b --mime-type "$entry" 2>/dev/null)
        if [[ "$filetype" =~ "executable" ]] || [[ "$filetype" =~ "script" ]] || 
           [[ "$entry" == *".desktop" ]] || [[ "$entry" == *".sh" ]]|| [[ "$entry" == *".py" ]]; then
          chmod -f 755 "$entry" >/dev/null 2>&1
        else
          chmod -f 644 "$entry" >/dev/null 2>&1
        fi
      elif [ -d "$entry" ]; then
        chmod -f 755 "$entry" >/dev/null 2>&1
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

function generate_motd(){
  mkdir -p /etc/update-motd.d >/dev/null 2>&1
  rm -f /etc/motd >/dev/null 2>&1
  rm -f /etc/update-motd.d/* >/dev/null 2>&1
  cat >>/etc/update-motd.d/10-sysinfo <<SIEOF
#!/bin/bash
export LC_ALL=C
export LANG=C
branch_sys="\$(awk 'NR==1 {print \$1}' /etc/imageinfo/sysinfo 2>/dev/null)"
[ "\$branch_sys" == "" ] && branch_sys="NONE"
version_sys="\$(awk 'NR==1 {print \$2}' /etc/imageinfo/sysinfo 2>/dev/null)"
[ "\$version_sys" == "" ] && version_sys="0"
branch_oem="\$(awk 'NR==1 {print \$1}' /etc/imageinfo/oeminfo 2>/dev/null)"
[ "\$branch_oem" == "" ] && branch_oem="NONE"
version_oem="\$(awk 'NR==1 {print \$2}' /etc/imageinfo/oeminfo 2>/dev/null)"
[ "\$version_oem" == "" ] && version_oem="0"
date=\$(date)
distro=\$(cat /etc/*release 2>/dev/null | grep "PRETTY_NAME" | cut -d "=" -f 2- | sed 's/"//g')
[ -z "\$distro" ] && [ -x /usr/bin/lsb_release ] && distro=\$(lsb_release -s -d)
raspi=\$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)
processor_name=\$(grep "model name" /proc/cpuinfo | cut -d ' ' -f3- | awk {'print \$0'} | head -1)
[ -z "\$processor_name" ] && processor_name=\$(lscpu | grep 'Model name' | cut -d ' ' -f3- | sed 's/^ *//')
processor_count=\$(grep -ioP 'processor\t:' /proc/cpuinfo | wc -l)
root_usage=\$(df -h / | awk '/\// {print \$(NF-1)}')
root_used=\$(df -h / | awk '/\// {print \$(NF-3)}')
root_total=\$(df -h / | awk '/\// {print \$(NF-4)}')
memory_usage=\$(free -m | awk '/Mem:/ { total=\$2 } /Mem:/ { used=\$3 } END { printf("%3.1f%%", (used/total)*100)}')
memory="\$(free -m | awk '/Mem:/ { print \$2 }')M"
memory_used="\$(free -m | awk '/Mem:/ { print \$3 }')M"
users=\$(w -s | grep -v WHAT | grep -v "load average" | wc -l)
uptime=\$(uptime -p | cut -d' ' -f2-)
ip_local=\$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
ip_global=\$(curl -s4 ifconfig.co)
W="\e[0;39m"
G="\e[1;32m"

printf "\033[1;32mWelcome to %s.\n\033[0m" "\$distro"
echo
printf "\033[1;37mSystem information as of: \$date\033[0m"
echo -e "
\$W  Distro......: \$W\$distro
\$W  Kernel......: \$W\`uname -sr\`
\$W  Raspi.......: \$W\$raspi
\$W  CPU.........: \$W\$processor_name (\$G\$processor_count\$W vCPU)
\$W  SYS Image...: \$W\$branch_sys (v\$G\$version_sys\$W)
\$W  OEM Image...: \$W\$branch_oem (v\$G\$version_oem\$W)

\$W  Uptime......: \$W\$uptime
\$W  IP local....: \$W\$ip_local
\$W  IP global...: \$W\$ip_global
\$W  Memory......: \$G\$memory_used\$W/\$G\$memory \$W(\$memory_usage)
\$W  Root........: \$G\$root_used\$W/\$G\$root_total \$W(\$root_usage)
\$W"
SIEOF
chmod 755 /etc/update-motd.d/10-sysinfo
}

function generate_network_config_files(){
  local filename=""
  local filename_short=""
  #NetworkManager
  if [ -n "$GEN_CONN_SSID" ]; then
    filename_short="${GEN_NET_INTERFACE}-${GEN_CONN_SSID}"
  else
    filename_short="${GEN_NET_INTERFACE}"
  fi
  filename="/etc/NetworkManager/system-connections/${filename_short}.nmconnection"
  if [ ! -e "$filename" ]; then
    cat >>"${filename}" <<NMEOF
[connection]
id=$filename_short
uuid=$(cat /proc/sys/kernel/random/uuid)
NMEOF
[ -n "$GEN_NET_POWERSAFE" ] && echo "type=wifi" >> "${filename}" ||  echo "type=ethernet" >> "${filename}"
echo "interface-name=$GEN_NET_INTERFACE" >> "${filename}"
echo "permissions=" >> "${filename}"
[ -n "$GEN_CONN_SSID" ] && cat >>"${filename}" <<NMEOF

[wifi]
mac-address-blacklist=
mode=infrastructure
ssid=$GEN_CONN_SSID
hidden=$GEN_CONN_HIDDEN
NMEOF
[ -n "$GEN_CONN_SSID" ] && [ -n "$GEN_CONN_KEY" ] && cat >>"${filename}" <<NMEOF

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$GEN_CONN_KEY
NMEOF
cat >>"${filename}" <<NMEOF

[ipv4]
dns-search=
method=$GEN_NET_MODE
NMEOF
[ -n "$GEN_NET_IPV4" ] && echo "addresses=$GEN_NET_IPV4" >> "${filename}"
[ -n "$GEN_NET_GATEWAY" ] && echo "gateway=$GEN_NET_GATEWAY" >> "${filename}"
[ -n "$GEN_NET_DNS" ] && echo "dns=$GEN_NET_DNS" >> "${filename}"
#ignore-auto-dns=true
cat >>"${filename}" <<NMEOF

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto

[proxy]
NMEOF
    chown -f 0:0 "${filename}"
    chmod -f 600 "${filename}"
  fi
  #dhcpcd
  if [ -n "$GEN_CONN_SSID" ]; then
    filename="/etc/wpa_supplicant/wpa_supplicant-${GEN_NET_INTERFACE}.conf"
    if [ ! -e "$filename" ]; then
      [ -n "$REGDOMAIN" ] && echo "country=$REGDOMAIN" >> "${filename}"
      cat >>"${filename}" <<WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
ap_scan=1

update_config=1
WPAEOF
    fi
    echo "network={" >> "${filename}"
    [ "$GEN_CONN_HIDDEN" != "false" ] && echo "  scan_ssid=1" >> "${filename}"
    echo "  ssid=\"$GEN_CONN_SSID\"" >> "${filename}"
    echo "  psk=$GEN_CONN_KEY" >> "${filename}"
    echo "}" >> "${filename}"
    chown -f 0:0 "${filename}"
    chmod -f 600 "${filename}"
  fi
  [ -z "$GEN_NET_IPV4" ] && [ -z "$GEN_NET_GATEWAY" ] && [ -z "$GEN_NET_DNS" ] && return 0
  filename="/etc/dhcpcd.conf"
  if ! grep -q "interface $GEN_NET_INTERFACE" "$filename"; then
    echo "#___IMGLDR_CONFIG_BEGIN___" >> "${filename}"
    echo "interface $GEN_NET_INTERFACE" >> "${filename}"
    [ -n "$GEN_NET_IPV4" ] && echo "static ip_address=$GEN_NET_IPV4" >> "${filename}"
    [ -n "$GEN_NET_GATEWAY" ] && echo "static routers=$GEN_NET_GATEWAY" >> "${filename}"
    [ -n "$GEN_NET_DNS" ] && echo "static domain_name_servers=$GEN_NET_DNS" >> "${filename}"
    echo "#___IMGLDR_CONFIG_END___" >> "${filename}"
  fi
}

function generate_network_config(){
  local wifi_network="/mnt/rootfs/CONFIG/wifi_network"
  local lan_network="/mnt/rootfs/CONFIG/lan_network"
  local filename
  [ -f /etc/dhcpcd.conf ] && sed -i '/#___IMGLDR_CONFIG_BEGIN___/,/#___IMGLDR_CONFIG_END___/d' /etc/dhcpcd.conf >/dev/null 2>&1
  rm -f /etc/wpa_supplicant/wpa_supplicant*.conf >/dev/null 2>&1
  rm -f /etc/NetworkManager/system-connections/imgldr_*.nmconnection >/dev/null 2>&1
  mkdir -p /etc/wpa_supplicant >/dev/null 2>&1
  mkdir -p /etc/NetworkManager/system-connections >/dev/null 2>&1
  for filename in ${wifi_network}* ; do
    GEN_CONN_SSID=$(config_read "$filename" ssid "")
    GEN_CONN_KEY=$(config_read "$filename" key "")
    GEN_CONN_HIDDEN=$(config_read "$filename" hidden "false")
    GEN_NET_INTERFACE=$(config_read "$filename" interface "wlan0")
    GEN_NET_POWERSAFE=$(config_read "$filename" powersafe "true")
    GEN_NET_MODE=$(config_read "$filename" mode "auto")
    GEN_NET_IPV4=$(config_read "$filename" ipv4addr "")
    GEN_NET_GATEWAY=$(config_read "$filename" gateway "")
    GEN_NET_DNS=$(config_read "$filename" dns_nameservers "")
    generate_network_config_files
  done
  GEN_CONN_SSID=""
  GEN_CONN_KEY=""
  GEN_CONN_HIDDEN=""
  GEN_NET_POWERSAFE=""
  for filename in ${lan_network}* ; do
    GEN_NET_INTERFACE=$(config_read "$filename" interface "eth0")
    GEN_NET_MODE=$(config_read "$filename" mode "auto")
    GEN_NET_IPV4=$(config_read "$filename" ipv4addr "")
    GEN_NET_GATEWAY=$(config_read "$filename" gateway "")
    GEN_NET_DNS=$(config_read "$filename" dns_nameservers "")
    generate_network_config_files
  done
}

function do_cleanup_image {
  #Remote-access unblock configuration
  systemctl enable vncserver-x11-serviced.service >/dev/null 2>&1
  vnc-web -e >/dev/null 2>&1
  systemctl enable cockpit.socket >/dev/null 2>&1
  systemctl enable ssh.service >/dev/null 2>&1
  #rebuildMachineID
  rm -f /etc/machine-id >/dev/null 2>&1
  rm -f /var/lib/dbus/machine-id >/dev/null 2>&1
  systemd-machine-id-setup
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  #rebuildSSHKeyPairs
  rm -f /etc/ssh/*_key* >/dev/null 2>&1
  ssh-keygen -A
  #cleanDHCPLeases
  rm -rf /var/lib/dhcp/* >/dev/null 2>&1
  #resetNetwork
  systemctl enable dhcpcd >/dev/null 2>&1
  systemctl enable NetworkManager >/dev/null 2>&1
  rm -f /etc/network/interfaces.d/* >/dev/null 2>&1
  rm -f /etc/NetworkManager/conf.d/* >/dev/null 2>&1
  [ -f /etc/dhcpcd.conf ] && sed -i '/#___IMGLDR_CONFIG_BEGIN___/,/#___IMGLDR_CONFIG_END___/d' /etc/dhcpcd.conf >/dev/null 2>&1
  #deleteWifiSettings
  rm -f /etc/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1
  rm -f /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null 2>&1
  echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev" > /etc/wpa_supplicant/wpa_supplicant.conf
  echo "update_config=1" >> /etc/wpa_supplicant/wpa_supplicant.conf
  #deleteVNCSettings
  rm -rf "/root/.vnc" >/dev/null 2>&1
  rm -rf "/home/"*"/.vnc" >/dev/null 2>&1
  #deleteVNC-webPassword
  rm -f "/etc/vnc-web/vncpasswd.pass" >/dev/null 2>&1
  # changeTimezone
  rm -f /etc/localtime
  echo "UTC" >/etc/timezone
  dpkg-reconfigure -f noninteractive tzdata
  # changeKeymap
  rm -f /etc/console-setup/cached_* >/dev/null 2>&1
  cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"

EOF
  dpkg-reconfigure -f noninteractive keyboard-configuration
  systemctl restart keyboard-setup
  setsid sh -c 'exec setupcon --save -k --force <> /dev/tty1 >&0 2>&1'
  udevadm trigger --subsystem-match=input --action=change
  #cleanPackageCache
  apt-get -y autoremove --purge
  apt-get -y clean
  apt-get -y autoclean
  #cleanBashHistory
  unset HISTFILE
  rm -f /root/.bash_history >/dev/null 2>&1
  rm -f "$FIRSTUSERHOME/.bash_history" >/dev/null 2>&1
  #cleanupSSLfiles
  rm -f /etc/cockpit/ws-certs.d/* >/dev/null 2>&1
  rm -f /etc/nginx/sites-enabled/vnc-web >/dev/null 2>&1
  rm -f /etc/vnc-web/sslcert.cert >/dev/null 2>&1
  #cleanLogFiles
  find /var/log -type f -delete >/dev/null 2>&1
  journalctl --rotate
  journalctl --vacuum-time=1s
  #changeHostname
  sed -i "s/127\.0\.1\.1.*$(</etc/hostname)/127.0.1.1\traspi/g" /etc/hosts
  echo "raspi" > /etc/hostname
  hostname -F /etc/hostname
  #wifi_country
  if grep -q "cfg80211.ieee80211_regdom=" $BOOTDIR/cmdline.txt; then
    sed -i 's|cfg80211\.ieee80211_regdom=[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt
    sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
  fi
  sed -i "s/^REGDOMAIN=.*$/REGDOMAIN=/" /etc/default/crda >/dev/null 2>&1
  rfkill block wifi >/dev/null 2>&1
  local filename
  for filename in /var/lib/systemd/rfkill/*:wlan ; do
    echo 1 > $filename
  done
  #resetSystemUser
  if [ "$FIRSTUSER" != "" ]; then
    echo "$FIRSTUSER:$FIRSTUSER" | chpasswd
    rm -rf "$FIRSTUSERHOME" >/dev/null 2>&1
    cp -rf /etc/skel "$FIRSTUSERHOME" >/dev/null 2>&1
    chown -R $FIRSTUSER:$FIRSTUSERGROUP "$FIRSTUSERHOME" >/dev/null 2>&1
  fi
  #cleanTmp
  find /tmp/ -mindepth 1 -delete >/dev/null 2>&1
  rm -rf /lost+found/* >/dev/null 2>&1
}

function generate_README {
  [ "${1}" != "short" ] && echo "Only in boot=image (image-overlayfs) mode script does following:"
  [ "${1}" != "short" ] && echo "Clear all logfiles every 15 minutes, disable swapfile and copies"
  [ "${1}" != "short" ] && echo "following configs to ofs image at boot:"
  echo "/CONFIG/admin_conf (openssl passwd -1 {password})"
  echo "                     username={username one word!; default: admin}"
  echo "                     password={password encrypted using openssl; default: admin}"
  echo "/CONFIG/hostname (single word no special chars)"
  echo "/CONFIG/keymap (us, de, ... only two lower letters)"
  echo "/CONFIG/timezone (America/Bogota, Europe/Berlin, UTC, CET, ..."
  echo "/CONFIG/network_config {dhcpcd/NetworkManager} (configuring network manager)"
  echo "/CONFIG/wifi_country (US, DE, ... only two upper letters)"
  echo "/CONFIG/wifi_network* (configuring wifi network)"
  echo "                     interface={IF_NAME; i.e. wlan0}"
  echo "                     powersafe={true/false}"
  echo "                     ssid={ssid name}"
  echo "                     key={optional; can be crypted; wpa_passphrase YOUR_SSID YOUR_PASSWORD}"
  echo "                     hidden={optional; true/false}"
  echo "                     mode={auto/manual}"
  echo "                     ipv4addr={optional; i.e. 192.168.2.100}"
  echo "                     gateway={optional; i.e. 192.168.10.1}"
  echo "                     dns_nameservers={optional; i.e. 192.168.10.1 8.8.8.8}"
  echo "                     powersafe={true/false}"
  echo "/CONFIG/lan_network* (configuring lan network)"
  echo "                     interface={IF_NAME; i.e. eth0}"
  echo "                     mode={auto/manual}"
  echo "                     ipv4addr={optional; i.e. 192.168.2.100}"
  echo "                     gateway={optional; i.e. 192.168.10.1}"
  echo "                     dns_nameservers={optional; i.e. 192.168.10.1 8.8.8.8}"
  echo "/CONFIG/remote_conf (enable/disable remote connections)"
  echo "                    real_vnc={true/false}"
  echo "                    vnc_web={true/false}"
  echo "                    cockpit={true/false}"
  echo "                    ssh={true/false}"
  #echo "                    pi_conn_linger={true/false}"
  #echo "                    pi_conn_shell={true/false}"
  #echo "                    pi_conn_vnc={true/false}"
  echo "/CONFIG/vnc-web_passwd (generate with 'vnc-web -p={password}'"
  echo "                        (not if SETUPMODE is active))"
  echo "/CONFIG/vnc-web_config (replace file '/etc/vnc-web/vnc.conf'"
  echo "                        (not if SETUPMODE is active))"
  echo "/CONFIG/kiosk_config (replace file '/etc/rpi-kiosk/kiosk.conf.d/kiosk.conf'"
  echo "                      (not if SETUPMODE is active))"
  echo "/CONFIG/auto-reboot_config (replace file '/etc/auto-reboot.config'"
  echo "                            (not if SETUPMODE is active))"
  echo "/CONFIG/ssl_cert (for use with vnc-web and cockpit; "
  echo "openssl req -x509 -newkey rsa:4096 -out {OUTPUT.cert} -keyout {OUTPUT.key} -sha256 -days 3650 -nodes -subj "/CN=$(hostname)""
  echo "                            (not if SETUPMODE is active))"
  echo "/CONFIG/ssl_key (for use with vnc-web and cockpit;"
  echo "openssl req -x509 -newkey rsa:4096 -out {OUTPUT.cert} -keyout {OUTPUT.key} -sha256 -days 3650 -nodes -subj "/CN=$(hostname)""
  echo "                            (not if SETUPMODE is active))"
  echo "/CONFIG/plymouth-splash/* (copy to overlay (not if SETUPMODE is active))"
  echo "/CONFIG/realvnc/root/* (copy to overlay (not if SETUPMODE is active))"
  echo "/CONFIG/realvnc/user/* (copy to overlay (not if SETUPMODE is active))"
  echo "/CONFIG/misc/* (direct copy to / in ofs (not if SETUPMODE is active))"
}

function cmd_cleanup_image {
  response="x"
  echo "Cleanup will: rebuildSSHKeyPairs, rebuildMachineID, cleanDHCPLeases,"
  echo "cleanTmp, cleanPackageCache, cleanBashHistory, cleanLogFiles,"
  echo "resetSystemUsersHome, deleteWifiSettings, changePasswordSystemUser"
  echo "changeHostname, changeTimezone, changeKeymap, wifi_country, unblock_remote_access"
  echo "You will lose wifi connection! Are you sure you want to do this?"
  echo "yes? (y), no? (n)"
  while [ "${response}" != "y" ] && [ "${response}" != "n" ]; do
    read -n 1 -s response
  done
  [ "$response" == "n" ] && return
  echo "please wait ..."
  set_boot_rw
  do_cleanup_image
  set_boot_ro
  sync >/dev/null 2>&1
  if [ -z "${SETUPMODE}" ] || [ -n "${noOverlay}" ]; then
    echo "Poweroff in 5 seconds ..."
    sleep 5
    poweroff -f
  else
    echo "Reboot in 5 seconds ..."
    sleep 5
    reboot -f
  fi
}

function cmd_preserv() {
  if [ -z "${noOverlay}" ] && [ -z "${islocked}" ]; then
    set_boot_rw
    touch "/run/${SCRIPT_TITLE}.lock"
    #bookworm boot_delay fix
    #systemctl mask dev-dri-card0.device >/dev/null 2>&1
    #systemctl mask dev-dri-renderD128.device >/dev/null 2>&1
    #setup some restrictions
    if [ -z "${SETUPMODE}" ]; then 
      echo -e '#!/bin/sh\necho "raspi-config is deactivated!"' > /usr/bin/raspi-config
      chmod +x /usr/bin/raspi-config
      echo -e '#!/bin/sh\necho "rpi-update is deactivated!"' > /usr/bin/rpi-update
      chmod +x /usr/bin/rpi-update
      apt-mark hold raspi-config rpi-update >/dev/null 2>&1
      [[ "$rasos_v" =~ "bullseye" ]] && apt-mark hold raspberrypi-kernel raspberrypi-bootloader >/dev/null 2>&1
    fi
    #generate motd
    generate_motd
    #rebuild_CONFIG_README
    if [ "$(generate_README short)" != "$(cat '/mnt/rootfs/CONFIG/README' 2>/dev/null)" ]; then
      echo "$(generate_README short)" > '/mnt/rootfs/CONFIG/README'
    fi
    #rebuildMachineID
    rm -f /etc/machine-id >/dev/null 2>&1
    rm -f /var/lib/dbus/machine-id >/dev/null 2>&1
    if [ -f /mnt/rootfs/STATIC/machine-id ]; then
      cp -f /mnt/rootfs/STATIC/machine-id /etc/machine-id
    fi
    systemd-machine-id-setup
    chmod 644 /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id
    if [ ! -f /mnt/rootfs/STATIC/machine-id ]; then
      mkdir -p "/mnt/rootfs/STATIC" >/dev/null 2>&1
      cp -f /etc/machine-id "/mnt/rootfs/STATIC/machine-id" >/dev/null 2>&1
    fi
    #rebuildSSHKeyPairs
    mkdir -p /etc/ssh
    rm -f /etc/ssh/*_key* >/dev/null 2>&1
    if ls /mnt/rootfs/STATIC/ssh_keys/*_key* >/dev/null 2>&1; then
      cp -f /mnt/rootfs/STATIC/ssh_keys/*_key* /etc/ssh/
      chmod 600 /etc/ssh/*_key*
    else
      ssh-keygen -A
      mkdir -p "/mnt/rootfs/STATIC/ssh_keys" >/dev/null 2>&1
      rm -f /mnt/rootfs/STATIC/ssh_keys/*_key* >/dev/null 2>&1
      cp -f /etc/ssh/*_key* "/mnt/rootfs/STATIC/ssh_keys/" >/dev/null 2>&1
    fi
    #SetupSystemUser
    if [ "$FIRSTUSER" != "" ]; then
      local admin_conf="/mnt/rootfs/CONFIG/admin_conf"
      local sysuser_name=$(config_read "$admin_conf" username "admin")
      local sysuser_pwd=$(config_read "$admin_conf" password '$1$25pgtsyy$hoEN68XR9byPK/RdSElWa/') #admin
      sysuser_name=$(echo "$sysuser_name" | awk 'NR==1 {print $1}' 2>/dev/null)
      sysuser_pwd=$(echo "$sysuser_pwd" | awk 'NR==1 {print $1}' 2>/dev/null)
      [ "$sysuser_name" == "" ] && sysuser_name="admin"
      [ "$sysuser_pwd" == "" ] && sysuser_pwd='$1$25pgtsyy$hoEN68XR9byPK/RdSElWa/'
      usermod -l $sysuser_name $FIRSTUSER >/dev/null 2>&1
      groupmod -n $sysuser_name $FIRSTUSERGROUP >/dev/null 2>&1
      FIRSTUSER="$sysuser_name"
      FIRSTUSERGROUP="$sysuser_name"
      usermod -p $sysuser_pwd $FIRSTUSER >/dev/null 2>&1
      if { [ -z "$SETUPMODE" ] && [ -z "$SAVEDBOOT" ]; } || [ "$FIRSTUSERHOME" != "/home/$FIRSTUSER" ]; then
        rm -rf $FIRSTUSERHOME >/dev/null 2>&1
        FIRSTUSERHOME="/home/$FIRSTUSER"
        usermod -d $FIRSTUSERHOME $FIRSTUSER >/dev/null 2>&1
        rm -rf $FIRSTUSERHOME >/dev/null 2>&1
        cp -rf /etc/skel $FIRSTUSERHOME >/dev/null 2>&1
        chown -R $FIRSTUSER:$FIRSTUSERGROUP $FIRSTUSERHOME >/dev/null 2>&1
      fi
      rm -f /etc/sudoers.d/010_*-nopasswd >/dev/null 2>&1
      echo "$FIRSTUSER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_${FIRSTUSER}-nopasswd
      chown 0:0 /etc/sudoers.d/010_${FIRSTUSER}-nopasswd >/dev/null 2>&1
      chmod -f 440 /etc/sudoers.d/010_${FIRSTUSER}-nopasswd >/dev/null 2>&1
    fi
    # Configuring plymouth
    # folder: /CONFIG/plymouth-splash/
    # --> is configured by imgldr_boot (image)
    #addSSLfiles
    local ssl_cert="/mnt/rootfs/STATIC/ssl_selfsigned.cert"
    local ssl_key="/mnt/rootfs/STATIC/ssl_selfsigned.key"
    if [ ! -f "$ssl_cert" ] || [ ! -f "$ssl_key" ]; then 
      mkdir -p "/mnt/rootfs/STATIC" >/dev/null 2>&1
      rm -f "/mnt/rootfs/STATIC/ssl_selfsigned.cert" >/dev/null 2>&1
      rm -f "/mnt/rootfs/STATIC/ssl_selfsigned.key" >/dev/null 2>&1
      openssl req -x509 -newkey rsa:4096 -out "/mnt/rootfs/STATIC/ssl_selfsigned.cert" -keyout "/mnt/rootfs/STATIC/ssl_selfsigned.key" -sha256 -days 3650 -nodes -subj "/" >/dev/null 2>&1
    fi
    [ -f "/mnt/rootfs/CONFIG/ssl_cert" ] && [ -f "/mnt/rootfs/CONFIG/ssl_key" ] && ssl_cert="/mnt/rootfs/CONFIG/ssl_cert" && ssl_key="/mnt/rootfs/CONFIG/ssl_key"
    if [ -f "$ssl_cert" ] && [ -f "$ssl_key" ]; then
      mkdir -p /etc/cockpit/ws-certs.d
      mkdir -p /etc/vnc-web
      mkdir -p /etc/ssl/private
      rm -f "/etc/cockpit/ws-certs.d/imgldr.cert"
      rm -f "/etc/cockpit/ws-certs.d/imgldr.key"
      cp -f "$ssl_cert" /etc/cockpit/ws-certs.d/imgldr.cert >/dev/null 2>&1
      chown -f 0:cockpit-ws "/etc/cockpit/ws-certs.d/imgldr.cert" >/dev/null 2>&1
      chmod -f 640 "/etc/cockpit/ws-certs.d/imgldr.cert" >/dev/null 2>&1
      cp -f "$ssl_key" /etc/cockpit/ws-certs.d/imgldr.key >/dev/null 2>&1
      chown -f 0:cockpit-ws "/etc/cockpit/ws-certs.d/imgldr.key" >/dev/null 2>&1
      chmod -f 640 "/etc/cockpit/ws-certs.d/imgldr.key" >/dev/null 2>&1
      rm -f "/etc/vnc-web/sslcert.cert"
      rm -f "/etc/vnc-web/sslcert.key"
      cp -f "$ssl_cert" /etc/vnc-web/sslcert.cert >/dev/null 2>&1
      chown -f 0:0 "/etc/vnc-web/sslcert.cert" >/dev/null 2>&1
      chmod -f 600 "/etc/vnc-web/sslcert.cert" >/dev/null 2>&1
      cp -f "$ssl_key" /etc/vnc-web/sslcert.key >/dev/null 2>&1
      chown -f 0:0 "/etc/vnc-web/sslcert.key" >/dev/null 2>&1
      chmod -f 600 "/etc/vnc-web/sslcert.key" >/dev/null 2>&1
      rm -f "/etc/ssl/private/selfsigned.cert"
      rm -f "/etc/ssl/private/selfsigned.key"
      cp -f "$ssl_cert" /etc/ssl/private/selfsigned.cert >/dev/null 2>&1
      chown -f 0:0 "/etc/ssl/private/selfsigned.cert" >/dev/null 2>&1
      chmod -f 600 "/etc/ssl/private/selfsigned.cert" >/dev/null 2>&1
      cp -f "$ssl_key" /etc/ssl/private/selfsigned.key >/dev/null 2>&1
      chown -f 0:0 "/etc/ssl/private/selfsigned.key" >/dev/null 2>&1
      chmod -f 600 "/etc/ssl/private/selfsigned.key" >/dev/null 2>&1
    fi
    # Configuring realvnc
    if ls "/mnt/rootfs/CONFIG/realvnc/root/"* >/dev/null 2>&1; then
      mkdir -p /root
      rm -rf "/root/.vnc" >/dev/null 2>&1
      cp -rf "/mnt/rootfs/CONFIG/realvnc/root" "/root/.vnc"
      set_base_perms "/root/.vnc"
    fi
    if [ "$FIRSTUSER" != "" ] && ls "/mnt/rootfs/CONFIG/realvnc/user/"* >/dev/null 2>&1; then
      mkdir -p "$FIRSTUSERHOME"
      rm -rf "$FIRSTUSERHOME/.vnc" >/dev/null 2>&1
      cp -rf "/mnt/rootfs/CONFIG/realvnc/user" "$FIRSTUSERHOME/.vnc"
      set_base_perms "$FIRSTUSERHOME/.vnc"
      chown -Rf $FIRSTUSER:$FIRSTUSERGROUP "$FIRSTUSERHOME/.vnc" >/dev/null 2>&1
    fi
    # Configuring vnc-web
    if [ -f "/mnt/rootfs/CONFIG/vnc-web_passwd" ] && [ -z "${SETUPMODE}" ]; then
      mkdir -p /etc/vnc-web
      rm -f "/etc/vnc-web/vncpasswd.pass"
      cp -f "/mnt/rootfs/CONFIG/vnc-web_passwd" "/etc/vnc-web/vncpasswd.pass"
      chown -f 0:0 "/etc/vnc-web/vncpasswd.pass" >/dev/null 2>&1
      chmod -f 600 "/etc/vnc-web/vncpasswd.pass" >/dev/null 2>&1
    fi
    if [ -f "/mnt/rootfs/CONFIG/vnc-web_config" ] && [ -z "${SETUPMODE}" ]; then
      mkdir -p /etc/vnc-web
      rm -f "/etc/vnc-web/vnc.conf"
      cp -f "/mnt/rootfs/CONFIG/vnc-web_config" "/etc/vnc-web/vnc.conf"
      chown -f 0:0 "/etc/vnc-web/vnc.conf" >/dev/null 2>&1
      chmod -f 644 "/etc/vnc-web/vnc.conf" >/dev/null 2>&1
    fi
    # Configuring kiosk
    if [ -f "/mnt/rootfs/CONFIG/kiosk_config" ] && [ -z "${SETUPMODE}" ]; then
      mkdir -p /etc/rpi-kiosk/kiosk.conf.d
      rm -f "/etc/rpi-kiosk/kiosk.conf.d/kiosk.conf"
      cp -f "/mnt/rootfs/CONFIG/kiosk_config" "/etc/rpi-kiosk/kiosk.conf.d/kiosk.conf"
      chown -f 0:0 "/etc/rpi-kiosk/kiosk.conf.d/kiosk.conf" >/dev/null 2>&1
      chmod -f 644 "/etc/rpi-kiosk/kiosk.conf.d/kiosk.conf" >/dev/null 2>&1
    fi
    # Configuring auto-reboot
    if [ -f "/mnt/rootfs/CONFIG/auto-reboot_config" ] && [ -z "${SETUPMODE}" ]; then
      rm -f "/etc/auto-reboot.config"
      cp -f "/mnt/rootfs/CONFIG/auto-reboot_config" "/etc/auto-reboot.config"
      chown -f 0:0 "/etc/auto-reboot.config" >/dev/null 2>&1
      chmod -f 644 "/etc/auto-reboot.config" >/dev/null 2>&1
    fi
    # Copy other configurations to image
    if ls "/mnt/rootfs/CONFIG/misc/"* >/dev/null 2>&1 && [ -z "${SETUPMODE}" ]; then
      set_base_perms "/mnt/rootfs/CONFIG/misc"
      cp -af "/mnt/rootfs/CONFIG/misc/"* "/"
    fi
    # Disable swapfile
    echo "#!/bin/bash" > /usr/sbin/dphys-swapfile
    echo "exit 0" >> /usr/sbin/dphys-swapfile
    # Change hostname
    local hostname="$(awk 'NR==1 {print $1}' /mnt/rootfs/CONFIG/hostname 2>/dev/null)"
    if [ "$hostname" != "" ]; then
      sed -i "s/127\.0\.1\.1.*$(</etc/hostname)/127.0.1.1\t$hostname/g" /etc/hosts
      echo "$hostname" > /etc/hostname
      hostname -F /etc/hostname
    fi
    # change timezone
    local timezone="$(awk 'NR==1 {print $1}' /mnt/rootfs/CONFIG/timezone 2>/dev/null)"
    if [ "$timezone" != "" ]; then
      rm -f /etc/localtime
      echo "$timezone" >/etc/timezone
      dpkg-reconfigure -f noninteractive tzdata
    fi
    # change keymap
    local keymap="$(awk 'NR==1 {print $1}' /mnt/rootfs/CONFIG/keymap 2>/dev/null)"
    if [ "$keymap" != "" ]; then
      rm -f /etc/console-setup/cached_* >/dev/null 2>&1
      cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$keymap"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"

EOF
      dpkg-reconfigure -f noninteractive keyboard-configuration
      systemctl is-active --quiet keyboard-setup && systemctl restart keyboard-setup
      udevadm trigger --subsystem-match=input --action=change
    fi
    ## Change wifi_country & unblock
    local wifi_country="$(awk 'NR==1 {print $1}' /mnt/rootfs/CONFIG/wifi_country 2>/dev/null)"
    if [ -n "$wifi_country" ] && grep -q ""^${wifi_country}[[:space:]]"" /usr/share/zoneinfo/iso3166.tab; then
      REGDOMAIN=$wifi_country
      if ! grep -q "cfg80211.ieee80211_regdom=$REGDOMAIN" $BOOTDIR/cmdline.txt; then
        sed -i 's|cfg80211\.ieee80211_regdom=[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt >/dev/null 2>&1
        sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
        sed -i "s/$/ cfg80211.ieee80211_regdom=$REGDOMAIN/g" $BOOTDIR/cmdline.txt
      fi
      sed -i "s/^REGDOMAIN=.*$/REGDOMAIN=$REGDOMAIN/" /etc/default/crda >/dev/null 2>&1
      iw reg set "$REGDOMAIN" >/dev/null 2>&1
      rfkill unblock wifi >/dev/null 2>&1
      local filename
      for filename in /var/lib/systemd/rfkill/*:wlan ; do
        echo 0 > $filename
      done
    fi
    ## network config
    local network_config="$(awk 'NR==1 {print $1}' /mnt/rootfs/CONFIG/network_config 2>/dev/null)"
    if [ "$network_config" == "dhcpcd" ]; then
      systemctl disable --now NetworkManager.service >/dev/null 2>&1
    else
      systemctl disable --now dhcpcd.service >/dev/null 2>&1
    fi
    generate_network_config
    ## Remote-access configuration
    local remote_conf="/mnt/rootfs/CONFIG/remote_conf"
    local remote_vnc_real=$(config_read "$remote_conf" real_vnc "true")
    local remote_vnc_web=$(config_read "$remote_conf" vnc_web "true")
    local remote_cockpit=$(config_read "$remote_conf" cockpit "true")
    local remote_ssh=$(config_read "$remote_conf" ssh "true")
    [[ "$remote_vnc_real" =~ "false" ]] && systemctl disable --now vncserver-x11-serviced.service >/dev/null 2>&1
    [[ "$remote_vnc_web" =~ "false" ]] && systemctl disable --now vnc-web.service >/dev/null 2>&1
    [[ "$remote_cockpit" =~ "false" ]] && systemctl disable --now cockpit.socket >/dev/null 2>&1
    [[ "$remote_ssh" =~ "false" ]] && systemctl disable --now ssh.service >/dev/null 2>&1
    set_boot_ro
  fi
}

function cmd_service() {
  # Clear log files every 15 minutes
  local counter=0
  local powersafe_active
  while true; do
    if [ -z "${noOverlay}" ] && [ -z "${SETUPMODE}" ] && [ -z "${SAVEDBOOT}" ] && [ $counter -le 0 ]; then
      find /var/log -type f -exec truncate -s 0 {} \; >/dev/null 2>&1
      journalctl --rotate >/dev/null 2>&1
      journalctl --vacuum-time=1s >/dev/null 2>&1
      fake-hwclock save >/dev/null 2>&1
    fi
    if [ $counter -le 0 ]; then
      counter=15
    else
      (( counter-- ))
    fi
    [ "$WIFI_NET_POWERSAFE" == "false" ] && [ "$(iw dev wlan0 get power_save 2>/dev/null)" == "Power save: on" ] && iw dev wlan0 set power_save off >/dev/null 2>&1
    sleep 60
  done
}

function cmd_reset_all() {
  set_boot_rw
  sed -i 's|RESET_OFS[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt >/dev/null 2>&1
  sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
  if grep RESET_ALL $BOOTDIR/cmdline.txt >/dev/null 2>&1; then
    sed -i 's|RESET_ALL[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt >/dev/null 2>&1
    sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
    echo "SAVEDBOOT data & /STORAGE folder will remain after reboot now!"
  else
    sed -i 's/$/ RESET_ALL/g' $BOOTDIR/cmdline.txt
    echo "SAVEDBOOT data & /STORAGE folder will be reset after reboot now!"
  fi
  set_boot_ro
}

function cmd_reset_ofs() {
  set_boot_rw
  sed -i 's|RESET_ALL[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt >/dev/null 2>&1
  sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
  if grep RESET_OFS $BOOTDIR/cmdline.txt >/dev/null 2>&1; then
    sed -i 's|RESET_OFS[^ ]* \{0,1\}||g' $BOOTDIR/cmdline.txt >/dev/null 2>&1
    sed -i 's|[ \t]*$||' $BOOTDIR/cmdline.txt
    echo "SAVEDBOOT data will remain after reboot now!"
  else
    sed -i 's/$/ RESET_OFS/g' $BOOTDIR/cmdline.txt
    echo "SAVEDBOOT will be reset after reboot now!"
  fi
  set_boot_ro
}

function cmd_generate_README() {
  if [ -z "${noOverlay}" ]; then
    if [ "$(generate_README short)" != "$(cat '/mnt/rootfs/CONFIG/README' 2>/dev/null)" ]; then
      rm -rf '/mnt/rootfs/CONFIG/README' >/dev/null 2>&1
      echo "$(generate_README short)" > '/mnt/rootfs/CONFIG/README'
      echo "README file recreated!"
    else
      echo "README file is already up to date!"
    fi
  else
    echo "Could not create README file! (not in 'image-overlayfs' mode)"
  fi
}

function cmd_print_version() {
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
}

function cmd_print_help() {
  echo "Usage: $SCRIPTNAME [OPTION]"
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
  echo " "
  generate_README
  echo " "
  echo "--generate_README       re/generate file: '/CONFIG/README'"
  echo "--cleanup_image         make distribution ready for create image"
  echo "-r, --RESET_ALL         un/set RESET_ALL flag in cmdline.txt (removes"
  echo "                        SAVEDBOOT data & '/STORAGE' folder after reboot)"
  echo "-R, --RESET_OFS         un/set RESET_OFS flag in cmdline.txt (removes"
  echo "                        SAVEDBOOT data only after reboot)"
  echo "-v, --version           print version info and exit"
  echo "-h, --help              print this help and exit"
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

[ "$CMD" != "version" ] && [ "$CMD" != "help" ] &&  do_check_start
[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "service" ]] && cmd_service
[[ "$CMD" == "preserv" ]] && cmd_preserv
[[ "$CMD" == "cleanup_image" ]] && cmd_cleanup_image
[[ "$CMD" == "generate_README" ]] && cmd_generate_README
[[ "$CMD" == "RESET_ALL" ]] && cmd_reset_all
[[ "$CMD" == "RESET_OFS" ]] && cmd_reset_ofs

exit $EXITCODE
