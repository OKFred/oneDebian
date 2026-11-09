#!/bin/bash
# Localize distribution sources while preserving suites, signatures and other repositories.

if ! declare -F the_os_release >/dev/null; then
  source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/the_os_release.sh" || return 1
fi

the_apt_source_state() {
  local os=$1 suite=$2
  shift 2
  awk -v os="$os" -v suite="$suite" '
    function reset() { uris=""; suites=""; types=""; enabled=""; field="" }
    function inspect(uri, releases, kinds, active, base_uri, security_uri) {
      gsub(/[ \t]+/," ",releases); gsub(/[ \t]+/," ",kinds)
      if (tolower(active)=="no" || (" " kinds " ") !~ / deb /) return
      if (os=="Debian") {
        base_uri=(uri ~ /^https?:\/\/(deb\.debian\.org|ftp\.debian\.org|ftp\.[a-z]+\.debian\.org|mirrors\.ustc\.edu\.cn)\/debian\/?$/)
        security_uri=(uri ~ /^https?:\/\/(deb\.debian\.org|mirrors\.ustc\.edu\.cn)\/debian-security\/?$/ || uri ~ /^https?:\/\/security\.debian\.org(\/debian-security)?\/?$/)
      } else {
        base_uri=(uri ~ /^https?:\/\/((([a-z]+\.)?archive|security)\.ubuntu\.com\/ubuntu|ports\.ubuntu\.com\/ubuntu-ports|mirrors\.tuna\.tsinghua\.edu\.cn\/ubuntu(-ports)?)\/?$/)
        security_uri=base_uri
      }
      if (base_uri && index(" " releases " ", " " suite " ")) base=1
      if (security_uri && index(" " releases " ", " " suite "-security ")) security=1
    }
    function flush( n, a, i) {
      n=split(uris,a,/[ \t]+/)
      for(i=1;i<=n;i++) inspect(a[i],suites,types,enabled)
      reset()
    }
    FNR==1 { flush() }
    /^[ \t]*#/ { next }
    FILENAME ~ /\.sources$/ {
      if (/^[ \t]*$/) { flush(); next }
      if (/^[^ \t][^:]*:/) {
        field=tolower($0); sub(/:.*/,"",field)
        value=$0; sub(/^[^:]*:[ \t]*/,"",value)
      } else if (/^[ \t]+/) { value=$0; sub(/^[ \t]+/,"",value) }
      else { next }
      sub(/[ \t]+$/, "", value)
      if(field=="uris") uris=uris " " value
      if(field=="suites") suites=suites " " value
      if(field=="types") types=types " " value
      if(field=="enabled") enabled=value
      next
    }
    /^[ \t]*deb(-src)?[ \t]/ {
      line=$0; sub(/[ \t]*#.*/,"",line); sub(/\[[^]]*\]/,"",line)
      sub(/^[ \t]+/,"",line); split(line,a,/[ \t]+/)
      inspect(a[2],a[3],a[1],"yes")
    }
    END { flush(); print base+0,security+0 }
  ' "$@"
}

the_localize_apt_sources() {
  local os=$1 suite=$2 apt_dir=${3:-/etc/apt} file temporary base security security_file uri arch keyring
  local -a files=()
  for file in "$apt_dir/sources.list" "$apt_dir/sources.list.d/"*.list "$apt_dir/sources.list.d/"*.sources; do
    if [ -L "$file" ]; then printf 'Source symlink requires manual review: %s\n' "$file" >&2; return 1; fi
    [ ! -f "$file" ] || files+=("$file")
  done
  if [ "${#files[@]}" -eq 0 ]; then printf 'No APT source files found.\n' >&2; return 1; fi
  read -r base security < <(the_apt_source_state "$os" "$suite" "${files[@]}")
  if [ "$base" != 1 ]; then printf 'No recognized active %s source for %s; review sources manually.\n' "$os" "$suite" >&2; return 1; fi
  security_file="$apt_dir/sources.list.d/onedebian-security.list"
  if [ "$security" != 1 ] && { [ -e "$security_file" ] || [ -L "$security_file" ]; }; then
    printf 'Existing security source requires manual review: %s\n' "$security_file" >&2
    return 1
  fi
  for file in "${files[@]}"; do
    temporary=$(mktemp "$file.onedebian.XXXXXXXX") || return 1
    if [ "$os" = Debian ]; then
      sed -E \
        -e '/^[[:space:]]*#/b' \
        -e 's#https?://security\.debian\.org(/debian-security)?/?([[:space:]]|$)#https://mirrors.ustc.edu.cn/debian-security\2#g' \
        -e 's#https?://(deb\.debian\.org|ftp\.debian\.org|ftp\.[a-z]+\.debian\.org)/debian(-security)?/?([[:space:]]|$)#https://mirrors.ustc.edu.cn/debian\2\3#g' \
        -e 's#http://mirrors\.ustc\.edu\.cn/debian(-security)?/?([[:space:]]|$)#https://mirrors.ustc.edu.cn/debian\1\2#g' \
        "$file" >"$temporary"
    else
      sed -E \
        -e '/^[[:space:]]*#/b' \
        -e 's#https?://(([a-z]+\.)?archive|security)\.ubuntu\.com/ubuntu/?([[:space:]]|$)#https://mirrors.tuna.tsinghua.edu.cn/ubuntu\3#g' \
        -e 's#https?://ports\.ubuntu\.com/ubuntu-ports/?([[:space:]]|$)#https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports\1#g' \
        -e 's#http://mirrors\.tuna\.tsinghua\.edu\.cn/ubuntu(-ports)?/?([[:space:]]|$)#https://mirrors.tuna.tsinghua.edu.cn/ubuntu\1\2#g' \
        "$file" >"$temporary"
    fi
    if [ "$?" -ne 0 ]; then rm -f -- "$temporary"; return 1; fi
    if ! cmp -s -- "$file" "$temporary"; then
      if [ -L "$file.onedebian.bak" ] || { [ -e "$file.onedebian.bak" ] && [ ! -f "$file.onedebian.bak" ]; }; then
        printf 'Unsafe backup path: %s\n' "$file.onedebian.bak" >&2
        rm -f -- "$temporary"; return 1
      fi
      if { [ -e "$file.onedebian.bak" ] || cp -p -- "$file" "$file.onedebian.bak"; } && cat "$temporary" >"$file"; then
        printf 'Localized APT source: %s\n' "$file"
      else
        rm -f -- "$temporary"; return 1
      fi
    fi
    rm -f -- "$temporary" || return 1
  done
  if [ "$security" != 1 ]; then
    uri=https://mirrors.ustc.edu.cn/debian-security
    keyring=/usr/share/keyrings/debian-archive-keyring.gpg
    if [ "$os" = Ubuntu ]; then
      keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
      arch=$(dpkg --print-architecture) || return 1
      case "$arch" in amd64|i386) uri=https://mirrors.tuna.tsinghua.edu.cn/ubuntu ;; *) uri=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports ;; esac
    fi
    mkdir -p -- "$apt_dir/sources.list.d" || return 1
    temporary=$(mktemp "$apt_dir/sources.list.d/.onedebian-security.XXXXXXXX") || return 1
    if printf 'deb [signed-by=%s] %s %s-security main\n' "$keyring" "$uri" "$suite" >"$temporary" && chmod 644 "$temporary" && mv -- "$temporary" "$security_file"; then
      printf 'Added security source: %s\n' "$security_file"
    else
      rm -f -- "$temporary"; return 1
    fi
  fi
}

the_repo_localization() {
  local os suite
  [ "$(id -u)" = 0 ] || { printf 'Root required.\n' >&2; return 1; }
  os=$(the_os_release) || return 1
  suite=$(the_code_name) || return 1
  case "$os" in Debian|Ubuntu) ;; *) printf 'Unsupported operating system: %s\n' "$os" >&2; return 1 ;; esac
  [[ "$suite" =~ ^[a-z][a-z0-9-]*$ ]] && [ "$suite" != false ] || { printf 'Invalid distribution codename.\n' >&2; return 1; }
  the_localize_apt_sources "$os" "$suite" || return 1
  apt-get -o APT::Update::Error-Mode=any update || return 1
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs
}
