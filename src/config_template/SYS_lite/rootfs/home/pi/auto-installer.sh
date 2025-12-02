#!/bin/bash
##############################################
##                                          ##
##  auto-installer                          ##
##                                          ##
##############################################

SCRIPT_TITLE="auto-installer"
SCRIPT_VERSION="1.2"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SYS_ARCH=$(dpkg --print-architecture)
PREREQS=( dpkg sed jq curl coreutils )
export LC_ALL=C
export LANG=C

for i in "$@"
do
  case $i in
    -V|--verbose)
    verbose="--verbose"
    shift # past argument
    ;;
    -q|--quiet)
    quiet="--quiet"
    shift # past argument
    ;;
    -f|--force)
    force="--force"
    shift # past argument
    ;;
    -i|--install)
    [ -z "$CMD" ] && CMD="install" || CMD="help"
    shift # past argument
    ;;
    -d|--deinstall)
    [ -z "$CMD" ] && CMD="deinstall" || CMD="help"
    shift # past argument
    ;;
    -v|--version)
    [ -z "$CMD" ] && CMD="version" || CMD="help"
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
[ -z "$CMD" ] && CMD="help"

handle_error() {
  local exit_code=$1
  local error_message="$2"
  if [ -z "$exit_code" ] || [ "$exit_code" == "0" ]; then
    exit_code=1
  fi
  echo -e "error: $error_message (Exit Code: $exit_code)"
  exit $exit_code
}

do_check_start() {
  if [ $UID -ne 0 ]; then
    handle_error "1" "This script can only run with Superuser privileges!"
  fi
  if ! [ -f "/etc/debian_version" ]; then
    handle_error "1" "This script is only supported on Debian-based systems."
  fi
  local apt
  local apt_res=""
  IFS=$' '
  if [ "${#PREREQS[@]}" -ne 0 ]; then
    for apt in "${PREREQS[@]}"; do
      if ! { dpkg -s "$apt" 2>/dev/null | grep -q '^Status: install ok installed'; }; then
        apt_res+="${apt} "
      fi
    done
    if [ -n "$apt_res" ]; then
      [ -z "$quiet" ] && echo "--> run apt-get update ..."
      if [ -z "$verbose" ]; then
        apt-get -qy update >/dev/null 2>&1
      else
        apt-get -qy update
      fi
      [ $? -ne 0 ] && handle_error "1" "apt-get update error! abort."
      [ -z "$quiet" ] && echo "--> install missing prerequisites: ${apt_res% } ..."
      if [ -z "$verbose" ]; then
        apt-get install -qq -- ${apt_res% } >/dev/null 2>&1
      else
        apt-get install -qq -- ${apt_res% }
      fi
      [ $? -ne 0 ] && handle_error "1" "Could not install prerequisites: ${apt_res% }! abort."
    fi
  fi
  unset IFS
}

scripts_setup() {
  local filetype
  local entry
  local test
  local old_IFS="$IFS"
  IFS=$'\n'
  test=($(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*$1.sh" 2>/dev/null))
  if [ "${#test[@]}" != "0" ]; then
    for entry in "${test[@]}"; do
      [[ "$entry" -ef "$SCRIPT_PATH" ]] && continue
      filetype=$(file -b --mime-type "$entry" 2>/dev/null)
      if [[ "$filetype" =~ "text" ]]
      then
        sed -i 's/\r$//g' "$entry" >/dev/null 2>&1
        filetype="$(file -b --mime-type "$entry" 2>/dev/null)"
      fi
      if [[ "$filetype" =~ "executable" ]] || [[ "$filetype" =~ "script" ]] || [[ "$entry" == *".sh" ]]; then
        chmod -f 755 "$entry"
        "$entry" $quiet $force $verbose
      fi
    done
  fi
  IFS="$old_IFS"
}

github_download() {
  local item
  local _items=()
  local conf_file="$SCRIPT_DIR/github.conf"
  local api_base="https://api.github.com"
  local etag_dir="$SCRIPT_DIR/.etag"
  mkdir -p "$etag_dir"
  [[ ! -e "$conf_file" ]] && return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    _items+=("$line")
  done < "$conf_file"
  for item in "${_items[@]}"; do
    local repo_raw
    local repo
    local tag
    local token
    local code
    local release_url
    local release_json
    local asset_lines=()
    repo_raw=$(awk '{print $1}' <<< "$item")
    if [[ "$repo_raw" == *[@:]* ]]; then
      repo="${repo_raw%%[@:]*}"
      tag="${repo_raw#"$repo"}"; tag="${tag:1}"
    else
      repo="$repo_raw"
      tag=""
    fi
    token=$(awk '{print $2}' <<< "$item")
    [[ -z "$repo" ]] && continue
    local safe_tag="${tag//[\/:]/_}"
    local base="$(echo -n "$repo" | tr '/' '_')${safe_tag:+_}$safe_tag"
    local etag_file="$etag_dir/$base.etag"
    local cache_json="$etag_dir/$base.json"
    local hdr="$(mktemp)"
    local body="$(mktemp)"
    local etag_header=()
    [[ -f "$etag_file" ]] && etag_header=(-H "If-None-Match: $(cat "$etag_file")")
    if [[ -n "$tag" ]]; then
      release_url="$api_base/repos/$repo/releases/tags/$tag"
    else
      release_url="$api_base/repos/$repo/releases/latest"
    fi
    [ -z "$quiet" ] && echo "--> get github-releases info: $repo${tag:+@$tag} ..."
    code=$(curl -fs ${verbose:+-vS} \
        -D "$hdr" \
        -w "%{http_code}" \
        -o "$body" \
        -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        ${token:+-H} ${token:+"Authorization: Bearer $token"} \
        "${etag_header[@]}" \
        "$release_url")
    if [[ "$code" == "304" ]]; then
      rm -f "$hdr" "$body"
      if [[ -f "$cache_json" ]]; then
        release_json="$(cat "$cache_json")"
      else
        release_json="$(curl -fsL ${verbose:+-vS} \
          -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          ${token:+-H} ${token:+"Authorization: Bearer $token"} \
          "$release_url")" || handle_error "1" "Could not receive release for repo $repo${tag:+@$tag}"
        echo "$release_json" > "$cache_json"
      fi
    else
      if [[ "$code" != "200" ]]; then
        rm -f "$hdr" "$body"
        handle_error "1" "Could not receive release for repo $repo${tag:+@$tag} (HTTP $code)"
      fi
      if grep -qi '^etag:' "$hdr"; then
        sed -n 's/^[eE][tT][aA][gG]: *//p' "$hdr" | tr -d '\r' > "$etag_file"
      fi
      release_json="$(cat "$body")"
      echo "$release_json" > "$cache_json"
      rm -f "$hdr" "$body"
    fi
    mapfile -t asset_lines < <(
      printf "%s\n" "$release_json" |
      jq -r '.assets[]? | select(.name|endswith(".deb")) | "\(.id)\t\(.name)\t\(.browser_download_url // "")\t\(.size // 0)"'
    )
    [[ ${#asset_lines[@]} -eq 0 ]] && handle_error "1" "Could not find any .deb-assets in repo $repo${tag:+@$tag}"
    for line in "${asset_lines[@]}"; do
      local id="${line%%$'\t'*}"
      local rest="${line#*$'\t'}"
      local name="${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
      local url="${rest%%$'\t'*}"
      local size="${rest#*$'\t'}"
      local dest="$SCRIPT_DIR/$name"
      local csum_url=""
      local csum_algo=""
      csum_url=$(printf "%s\n" "$release_json" | jq -r --arg n "$name" '
        .assets[]? | select(
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha256")     or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha256sum")  or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha256.txt") or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha512")     or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha512sum")  or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha512.txt") or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha1")       or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha1sum")    or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".sha1.txt")   or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".md5")        or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".md5sum")     or
            ((.name|ascii_downcase)==($n|ascii_downcase)+".md5.txt")
          ) | (.browser_download_url // "")' | head -n1)
      if [[ -n "$csum_url" ]]; then
        case "$csum_url" in
          *.sha256* ) csum_algo="sha256" ;;
          *.sha512* ) csum_algo="sha512" ;;
          *.sha1*   ) csum_algo="sha1"   ;;
          *.md5*    ) csum_algo="md5"    ;;
        esac
      fi
      if [[ -f "$dest" ]] && [[ -z "$force" ]]; then
        local cur_size
        cur_size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [[ "$size" -gt 0 && "$cur_size" -eq "$size" ]]; then
          if [[ -n "$csum_url" && -n "$csum_algo" ]]; then
            local csum_txt
            local expected
            local got
            csum_txt=$(curl -fsL ${verbose:+-vS} \
                        -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
                        ${token:+-H} ${token:+"Authorization: Bearer $token"} \
                        "$csum_url" || true)
            case "$csum_algo" in
              sha512) expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{128}$/){print tolower($i); exit}}'); got=$(sha512sum "$dest" | awk '{print $1}') ;;
              sha256) expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{64}$/){print tolower($i); exit}}');  got=$(sha256sum "$dest" | awk '{print $1}') ;;
              sha1)   expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{40}$/){print tolower($i); exit}}');  got=$(sha1sum   "$dest" | awk '{print $1}') ;;
              md5)    expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{32}$/){print tolower($i); exit}}');  got=$(md5sum    "$dest" | awk '{print $1}') ;;
            esac
            expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
            got=$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')
            if [[ -n "$expected" && "$got" == "$expected" ]]; then
              [ -z "$quiet" ] && echo "Skipping (size & checksum ok): $repo${tag:+@$tag} → $name"
              continue
            fi
          else
            [ -z "$quiet" ] && echo "Skipping download (up-to-date): $repo${tag:+@$tag} → $name"
            continue
          fi
        fi
      fi
      [ -z "$quiet" ] && echo "--> Download: $repo${tag:+@$tag} → $name ..."
      local downloaded="no"
      if [[ -n "$url" ]] && curl -fsL ${verbose:+-vS} \
           -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
           "$url" -o "$dest"; then
        downloaded="yes"
      else
        curl -fsL ${verbose:+-vS} \
          -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
          -H "Accept: application/octet-stream" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          ${token:+-H} ${token:+"Authorization: Bearer $token"} \
          "$api_base/repos/$repo/releases/assets/$id" \
          -o "$dest" || handle_error "1" "Download error: $repo${tag:+@$tag} → $name"
        downloaded="yes"
      fi
      if [[ "$downloaded" == "yes" && -n "$csum_url" && -n "$csum_algo" ]]; then
        local csum_txt
        local expected
        local got
        csum_txt=$(curl -fsL ${verbose:+-vS} \
                    -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
                    ${token:+-H} ${token:+"Authorization: Bearer $token"} \
                    "$csum_url" || true)
        case "$csum_algo" in
          sha512) expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{128}$/){print tolower($i); exit}}'); got=$(sha512sum "$dest" | awk '{print $1}') ;;
          sha256) expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{64}$/){print tolower($i); exit}}');  got=$(sha256sum "$dest" | awk '{print $1}') ;;
          sha1)   expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{40}$/){print tolower($i); exit}}');  got=$(sha1sum   "$dest" | awk '{print $1}') ;;
          md5)    expected=$(printf "%s\n" "$csum_txt" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{32}$/){print tolower($i); exit}}');  got=$(md5sum    "$dest" | awk '{print $1}') ;;
        esac
        expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
        got=$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')
        if [[ -z "$expected" ]]; then
          handle_error "1" "Checksum file found but no hash parsed for $name"
        fi
        if [[ "$got" != "$expected" ]]; then
          rm -f "$dest"
          handle_error "1" "Checksum mismatch: $repo${tag:+@$tag} → $name"
        fi
      fi
    done
  done
}

download_files() {
  local item
  local _items=()
  local conf_file="$SCRIPT_DIR/download.conf"
  local etag_dir="$SCRIPT_DIR/.etag"
  mkdir -p "$etag_dir"
  [[ ! -e "$conf_file" ]] && return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    _items+=("$line")
  done < "$conf_file"
  for item in "${_items[@]}"; do
    local url=$(awk '{print $1}' <<< "$item")
    local dest_field=$(awk '{print $2}' <<< "$item")
    local checksum_field=$(awk '{print $3}' <<< "$item")
    local algo
    local expected
    local name_from_url="${url##*/}"
    name_from_url="${name_from_url%%\?*}"
    local dest="$name_from_url"
    local safe_key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
    local etag_file="$etag_dir/$safe_key.etag"
    local lm_file="$etag_dir/$safe_key.lm"
    local hdr="$(mktemp)"
    local tmp="$(mktemp)"
    local code
    local etag_header=()
    [[ -z "$url" ]] && continue
    if [[ -z "$checksum_field" && -n "$dest_field" ]]; then
      if [[ "$dest_field" =~ ^(sha512:|sha256:|sha1:|md5:)[0-9A-Fa-f]+$ \
          || "$dest_field" =~ ^[0-9A-Fa-f]{128}$ \
          || "$dest_field" =~ ^[0-9A-Fa-f]{64}$ \
          || "$dest_field" =~ ^[0-9A-Fa-f]{40}$ \
          || "$dest_field" =~ ^[0-9A-Fa-f]{32}$ ]]; then
        checksum_field="$dest_field"
        dest_field=""
      fi
    fi
    [[ -n "$dest_field" ]] && dest="$dest_field"
    [[ -f "$etag_file" ]] && etag_header=(-H "If-None-Match: $(cat "$etag_file")")
    [[ -f "$lm_file" ]] && etag_header+=(-H "If-Modified-Since: $(cat "$lm_file")")
    code=$(curl -fsL ${verbose:+-vS} \
            -D "$hdr" \
            -w "%{http_code}" \
            -o "$tmp" \
            -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
            "${etag_header[@]}" \
            "$url")
    if [[ "$code" == "304" ]]; then
      if [[ ! -f "$SCRIPT_DIR/$dest" ]]; then
        [ -z "$quiet" ] && echo "--> re-downloading: $dest"
        code=$(curl -fsL ${verbose:+-vS} \
                -D "$hdr" \
                -w "%{http_code}" \
                -o "$tmp" \
                -H "User-Agent: $SCRIPT_TITLE/$SCRIPT_VERSION" \
                "$url")
        if [[ "$code" != "200" && "$code" != "206" ]]; then
          rm -f "$hdr" "$tmp"
          handle_error "1" "Could not download: $url (HTTP $code)"
        fi
      else
        rm -f "$hdr" "$tmp"
        if [[ -n "$checksum_field" ]]; then
          expected="$checksum_field"
          if [[ "$expected" == sha512:* ]]; then algo=sha512; expected="${expected#sha512:}"
          elif [[ "$expected" == sha256:* ]]; then algo=sha256; expected="${expected#sha256:}"
          elif [[ "$expected" == sha1:* ]]; then algo=sha1; expected="${expected#sha1:}"
          elif [[ "$expected" == md5:* ]]; then algo=md5; expected="${expected#md5:}"
          else
            case "${#expected}" in 128) algo=sha512;; 64) algo=sha256;; 40) algo=sha1;; 32) algo=md5;; *) algo="";; esac
          fi
          if [[ -n "$algo" ]]; then
            local got=""
            [[ "$algo" == "sha512" ]] && got=$(sha512sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
            [[ "$algo" == "sha256" ]] && got=$(sha256sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
            [[ "$algo" == "sha1"   ]] && got=$(sha1sum   "$SCRIPT_DIR/$dest" | awk '{print $1}')
            [[ "$algo" == "md5"    ]] && got=$(md5sum    "$SCRIPT_DIR/$dest" | awk '{print $1}')
            [[ "$got" != "$expected" ]] && handle_error "1" "Checksum mismatch (304): $dest"
          fi
        fi
        [ -z "$quiet" ] && echo "Skipping (up-to-date): $dest"
        continue
      fi
    fi
    if [[ "$code" != "200" && "$code" != "206" ]]; then
      rm -f "$hdr" "$tmp"
      handle_error "1" "Could not download: $url (HTTP $code)"
    fi
    if [[ -z "$dest_field" ]]; then
      local cd_line
      local fn_star
      local fn_star_dec
      local fn
      cd_line=$(sed -n 's/^[cC][oO][nN][tT][eE][nN][tT]-[dD][iI][sS][pP][oO][sS][iI][tT][iI][oO][nN]: *//p' "$hdr" | tr -d '\r' | tail -n1)
      if [[ -n "$cd_line" ]]; then
        fn_star=$(echo "$cd_line" | sed -n "s/.*filename\\*= *[^']*'[^']*'\\([^;]*\\).*/\\1/p")
        if [[ -n "$fn_star" ]]; then
          fn_star_dec=$(printf '%b' "${fn_star//%/\\x}")
          fn_star_dec="$(basename "$fn_star_dec")"
          [[ -n "$fn_star_dec" ]] && dest="$fn_star_dec"
        else
          fn=$(echo "$cd_line" | awk -F'filename=' '{if (NF>1){print $2}}' | sed 's/^"//; s/".*//; s/;.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
          [[ -n "$fn" ]] && dest="$(basename "$fn")"
        fi
      fi
    fi
    [[ -z "$dest" ]] && dest="$name_from_url"
    if [[ "$dest" = /* || "$dest" == *"/.."* || "$dest" == *"../"* || "$dest" == "./"* || "$dest" == *"/./"* ]]; then
      handle_error "1" "Illegal Destination: $dest"
    fi
    [ -z "$quiet" ] && echo "--> download file: $url -> $dest"
    if grep -qi '^etag:' "$hdr"; then
      sed -n 's/^[eE][tT][aA][gG]: *//p' "$hdr" | tr -d '\r' > "$etag_file"
    fi
    if grep -qi '^last-modified:' "$hdr"; then
      sed -n 's/^[lL][aA][sS][tT]-[mM][oO][dD][iI][fF][iI][eE][dD]: *//p' "$hdr" | tr -d '\r\n' > "$lm_file"
    fi
    if [[ -z "$force" && -f "$SCRIPT_DIR/$dest" ]]; then
      local cl
      local local_size
      cl=$(sed -n 's/^[cC][oO][nN][tT][eE][nN][tT]-[lL][eE][nN][gG][tT][hH]: *//p' "$hdr" | tr -d '\r\n' | tail -n1)
      cl=$(printf '%s' "$cl" | tr -cd '0-9')
      if [[ -n "$cl" ]]; then
        cl=$((10#$cl))
        local_size=$(stat -c%s "$SCRIPT_DIR/$dest" 2>/dev/null || echo 0)
        if [[ "$local_size" -eq "$cl" ]]; then
          if [[ -n "$checksum_field" ]]; then
            expected="$checksum_field"
            if [[ "$expected" == sha512:* ]]; then algo=sha512; expected="${expected#sha512:}"
            elif [[ "$expected" == sha256:* ]]; then algo=sha256; expected="${expected#sha256:}"
            elif [[ "$expected" == sha1:* ]]; then algo=sha1; expected="${expected#sha1:}"
            elif [[ "$expected" == md5:* ]]; then algo=md5; expected="${expected#md5:}"
            else
              case "${#expected}" in 128) algo=sha512;; 64) algo=sha256;; 40) algo=sha1;; 32) algo=md5;; *) algo="";; esac
            fi
            if [[ -n "$algo" ]]; then
              local got=""
              [[ "$algo" == "sha512" ]] && got=$(sha512sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
              [[ "$algo" == "sha256" ]] && got=$(sha256sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
              [[ "$algo" == "sha1"   ]] && got=$(sha1sum   "$SCRIPT_DIR/$dest" | awk '{print $1}')
              [[ "$algo" == "md5"    ]] && got=$(md5sum    "$SCRIPT_DIR/$dest" | awk '{print $1}')
              if [[ "$got" == "$expected" ]]; then
                rm -f "$hdr" "$tmp"
                [ -z "$quiet" ] && echo "Skipping (same size & checksum): $dest"
                continue
              fi
            else
              rm -f "$hdr" "$tmp"
              [ -z "$quiet" ] && echo "Skipping (same size): $dest"
              continue
            fi
          else
            rm -f "$hdr" "$tmp"
            [ -z "$quiet" ] && echo "Skipping (same size): $dest"
            continue
          fi
        fi
      fi
    fi
    mkdir -p "$(dirname "$SCRIPT_DIR/$dest")"
    mv -f "$tmp" "$SCRIPT_DIR/$dest"
    rm -f "$hdr"
    if [[ -n "$checksum_field" ]]; then
      expected="$checksum_field"
      if [[ "$expected" == sha512:* ]]; then algo=sha512; expected="${expected#sha512:}"
      elif [[ "$expected" == sha256:* ]]; then algo=sha256; expected="${expected#sha256:}"
      elif [[ "$expected" == sha1:* ]]; then algo=sha1; expected="${expected#sha1:}"
      elif [[ "$expected" == md5:* ]]; then algo=md5; expected="${expected#md5:}"
      else
        case "${#expected}" in 128) algo=sha512;; 64) algo=sha256;; 40) algo=sha1;; 32) algo=md5;; *) algo="";; esac
      fi
      if [[ -n "$algo" ]]; then
        local got=""
        [[ "$algo" == "sha512" ]] && got=$(sha512sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
        [[ "$algo" == "sha256" ]] && got=$(sha256sum "$SCRIPT_DIR/$dest" | awk '{print $1}')
        [[ "$algo" == "sha1"   ]] && got=$(sha1sum   "$SCRIPT_DIR/$dest" | awk '{print $1}')
        [[ "$algo" == "md5"    ]] && got=$(md5sum    "$SCRIPT_DIR/$dest" | awk '{print $1}')
        if [[ "$got" != "$expected" ]]; then
          rm -f "$SCRIPT_DIR/$dest"
          handle_error "1" "Checksum mismatch: $dest"
        fi
      fi
    fi
  done
}

deb_setup() {
  local filetype
  local deb_file
  local deb_pkg
  local deb_arch
  local deb_ver
  local inst_ver
  local entry
  local test
  local old_IFS="$IFS"
  IFS=$'\n'
  test=($(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.deb" 2>/dev/null))
  if [ "${#test[@]}" != "0" ]; then
    if [ "$1" == "" ]; then
      [ -z "$quiet" ] && echo "--> run apt-get update ..."
      if [ -z "$verbose" ]; then
        apt-get -qy update >/dev/null 2>&1
      else
        apt-get -qy update
      fi
      [ $? -ne 0 ] && handle_error "1" "apt-get update error! abort."
    fi
    for entry in "${test[@]}"; do
      filetype=$(file -b --mime-type "$entry" 2>/dev/null)
      if [[ "$filetype" =~ "package" ]] || [[ "${entry##*.}" == "deb" ]]; then
        deb_file=$(basename "$entry")
        deb_pkg=$(dpkg-deb -f "$entry" Package 2>/dev/null)
        deb_arch=$(dpkg-deb -f "$entry" Architecture 2>/dev/null)
        deb_ver=$(dpkg-deb -f "$entry" Version 2>/dev/null)
        inst_ver=$(dpkg -s -- "$deb_pkg" 2>/dev/null | awk '/^Version:/{print $2}')
        if [[ -z "$deb_pkg" ]] || [[ -z "$deb_arch" ]] || [[ -z "$deb_ver" ]]; then
          handle_error "1" "Package error: $deb_file (missing Package/Architecture/Version) ! abort."
        elif [ "$deb_arch" = "$SYS_ARCH" ] || [ "$deb_arch" = "all" ]; then
          if [[ -n "$force" ]] && [[ -z "$1" ]]; then
            [ -z "$quiet" ] && echo "--> force install: $deb_file ..."
            if [ -z "$verbose" ]; then
              apt-get install -qq --reinstall --allow-downgrades -- "$entry" >/dev/null 2>&1
            else
              apt-get install -qq --reinstall --allow-downgrades -- "$entry"
            fi
            [ $? -ne 0 ] && handle_error "1" "install error: $deb_file ! abort."
          elif [[ -n "$force" ]] && [ "$1" == "-d" ]; then
            [ -z "$quiet" ] && echo "--> force deinstall: $deb_file ..."
            if [ -z "$verbose" ]; then
              apt-get remove -qq -- "$deb_pkg" >/dev/null 2>&1
            else
              apt-get remove -qq -- "$deb_pkg"
            fi
            [ $? -ne 0 ] && handle_error "1" "deinstall error: $deb_file ! abort."
          elif [[ -n "$inst_ver" ]] && dpkg --compare-versions "$deb_ver" eq "$inst_ver" && [[ -z "$1" ]]; then
            [ -z "$quiet" ] && echo "Skipping installation (up-to-date): $deb_file"
          elif ( [[ -z "$inst_ver" ]] || dpkg --compare-versions "$deb_ver" gt "$inst_ver" ) && [[ -z "$1" ]]; then
            [ -z "$quiet" ] && echo "--> install: $deb_file ..."
            if [ -z "$verbose" ]; then
              apt-get install -qq -- "$entry" >/dev/null 2>&1
            else
              apt-get install -qq -- "$entry"
            fi
            [ $? -ne 0 ] && handle_error "1" "install error: $deb_file ! abort."
          elif [[ -z "$inst_ver" ]] && [ "$1" == "-d" ]; then
            [ -z "$quiet" ] && echo "Skipping (not installed): $deb_file"
          elif [[ -n "$inst_ver" ]] && [ "$1" == "-d" ]; then
            [ -z "$quiet" ] && echo "--> deinstall: $deb_file ..."
            if [ -z "$verbose" ]; then
              apt-get remove -qq -- "$deb_pkg" >/dev/null 2>&1
            else
              apt-get remove -qq -- "$deb_pkg"
            fi
            [ $? -ne 0 ] && handle_error "1" "deinstall error: $deb_file ! abort."
          fi
        else
          [ -z "$quiet" ] && echo "Skipping $deb_file (arch: $deb_arch, needed: $SYS_ARCH)"
        fi
      fi
    done
  fi
  IFS="$old_IFS"
}

function cmd_install() {
  scripts_setup preinst
  github_download
  download_files
  deb_setup
  scripts_setup postinst
}

function cmd_deinstall() {
  scripts_setup prerm
  github_download
  download_files
  deb_setup -d
  scripts_setup postrm
}

function cmd_print_version() {
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
}

function cmd_print_help() {
  echo "Usage: $SCRIPT_NAME [OPTION]"
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
  echo " "
  echo "A lightweight shell script to automatically run installer"
  echo "scripts and install or deinstall '.deb' packages from"
  echo "the script directory (picks the right package for os architecture)."
  echo "It can download deb packages from http and/or GitHub Releases assets."
  echo "- run '*preinst.sh'/'*prerm.sh' scripts"
  echo "- download '.deb' files from GitHub Releases (from 'github.conf')"
  echo "- Download '.deb' files from any http address (from 'download.conf')"
  echo "- de-/install '.deb' files found in the script directory"
  echo "- run '*postinst.sh'/'*postrm.sh' scripts"
  echo " "
  echo "-i, --install           run scripts and install all packages"
  echo "-d, --deinstall         run scripts and deinstall all packages"
  echo "-f, --force             force deinstall or reinstall packages"
  echo "-q, --quiet             do not print informations while de-/installation"
  echo "-V, --verbose           print detailed information during de-/installation"
  echo "-v, --version           print version info and exit"
  echo "-h, --help              print this help and exit"
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

[ "$CMD" != "version" ] && [ "$CMD" != "help" ] &&  do_check_start
[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "install" ]] && cmd_install
[[ "$CMD" == "deinstall" ]] && cmd_deinstall

exit 0