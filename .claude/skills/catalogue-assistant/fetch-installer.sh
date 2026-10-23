#!/bin/bash
# fetch-installer.sh: the catalogue assistant's access to the group's server.
# Downloads installers already on the server into a temporary folder, with
# ReaperPluginManager's own settings (config.ini) and the server password from
# the OS secret store, and reports each file's type, generator, size and
# SHA-256. Targets bash 3.2 (macOS) and Git Bash (Windows).
#
#   fetch-installer.sh datadir                     prints the tool's local data folder
#   fetch-installer.sh fetch <server path> [...]   downloads into a new temporary folder
#   fetch-installer.sh clean <folder>              deletes a folder `fetch` made
#
# `fetch` prints, one line each, tab-separated after the first word:
#   DIR  <folder>                                  only when at least one file arrived
#   OK   <server path> <local path> <size> <sha256> <kind> <generator>
#   FAIL <server path> <reason>
#   ERROR <reason>                                 nothing could be fetched
# kind: exe | msi | zip | pkg | dmg | unknown
# generator: inno | nsis | installshield | wix-burn | wix | msi | none | unknown
# Exit codes: 0 every file fetched, 1 a file or the setup failed, 2 usage.
#
# The password never reaches a command line or the output: it travels from the
# secret-store helper's output into a netrc file inside the temporary folder,
# owner-only, which is deleted before this script returns. The folder itself
# stays for inspection until `clean` deletes it. REAPER_RESOURCE_PATH
# overrides REAPER's resource path for a portable install.

SERVICE_PREFIX="ReaperPluginManager:"
CONNECT_TIMEOUT=30
STALL_TIMEOUT=60
MARKER=".rpm-fetch"
TAB=$(printf '\t')

work= netrc= keep= secret=

script_dir=$(cd "$(dirname "$0")" && pwd)

case "$(uname -s)" in
  Darwin) platform=macos ;;
  MINGW*|MSYS*|CYGWIN*) platform=windows ;;
  *) platform=other ;;
esac

usage() {
  echo "usage: fetch-installer.sh datadir | fetch <server path> [...] | clean <folder>" >&2
  exit 2
}

fail() {
  echo "ERROR $1"
  exit 1
}

# Native form of a path: Windows form under Git Bash, unchanged elsewhere.
to_native() {
  if [ "$platform" = windows ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

# POSIX form of a path, for this shell's own file operations.
to_unix() {
  if [ "$platform" = windows ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# Lowercase hex of the bytes of $1, two digits per byte.
to_hex() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

data_dir() {
  local resource
  if [ -n "$REAPER_RESOURCE_PATH" ]; then
    resource=$(to_unix "$REAPER_RESOURCE_PATH")
  elif [ "$platform" = windows ]; then
    [ -n "$APPDATA" ] || return 1
    resource="$(to_unix "$APPDATA")/REAPER"
  elif [ "$platform" = macos ]; then
    resource="$HOME/Library/Application Support/REAPER"
  else
    return 1
  fi
  printf '%s\n' "${resource%/}/ReaperPluginManager"
}

# The [server] url, user, tls and insecure values of config.ini, one per
# line, read by the same rules as rpm_core's INI parser: section and key
# names case-insensitive, a comment opens at a ; or # that starts the line or
# follows whitespace.
read_server_settings() {
  LC_ALL=C awk '
    {
      line = $0
      sub(/\r$/, "", line)
      if (NR == 1 && substr(line, 1, 3) == "\357\273\277") line = substr(line, 4)
      if (line ~ /^[;#]/) line = ""
      else if (match(line, /[ \t][;#]/)) line = substr(line, 1, RSTART - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      if (line ~ /^\[.*\]$/) {
        section = tolower(substr(line, 2, length(line) - 2))
        gsub(/^[ \t]+|[ \t]+$/, "", section)
        next
      }
      eq = index(line, "=")
      if (eq == 0) next
      key = tolower(substr(line, 1, eq - 1))
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      value = substr(line, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (section == "server" && key != "") v[key] = value
    }
    END { printf "%s\n%s\n%s\n%s\n", v["url"], v["user"], v["tls"], v["insecure"] }
  ' "$1"
}

# The lowercased host of a server URL; empty when it has none (file://).
url_host() {
  local rest authority host
  rest=$(printf '%s' "$1" | sed -n 's|^[A-Za-z][A-Za-z0-9+.-]*://||p')
  authority=${rest%%[/?#]*}
  authority=${authority##*@}
  case "$authority" in
    \[*) host="${authority%%]*}]" ;;
    *) host=${authority%%:*} ;;
  esac
  lower "$host"
}

# ftp, http or file, from the URL scheme; empty for any other.
url_kind() {
  case "$(lower "${1%%://*}")" in
    ftp|ftps) echo ftp ;;
    http|https) echo http ;;
    file) echo file ;;
  esac
}

# A server path in URL form: \ becomes /, leading slashes go, every byte
# outside [A-Za-z0-9-._~/] is percent-encoded.
encode_path() {
  local p=$1 out= h
  p=${p//\\//}
  while [ "${p#/}" != "$p" ]; do p=${p#/}; done
  for h in $(printf '%s' "$p" | od -An -v -tx1); do
    case "$h" in
      2d|2e|2f|3[0-9]|4[1-9a-f]|5[0-9a]|5f|6[1-9a-f]|7[0-9a]|7e) out="$out$(printf "\\x$h")" ;;
      *) out="$out%$(printf '%s' "$h" | tr 'a-f' 'A-F')" ;;
    esac
  done
  printf '%s\n' "$out"
}

# The filesystem path of server path $2 on the file:// server $1.
file_server_path() {
  local rest=${1#*://} p path=$2
  rest=${rest//\\//}
  case "$rest" in
    /*|[A-Za-z]:*) p=$rest ;;
    [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]/*) p=${rest:9} ;;
    *) p="//$rest" ;;
  esac
  case "$p" in
    /[A-Za-z]:*) p=${p#/} ;;
  esac
  p=$(printf '%b' "$(printf '%s' "$p" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')")
  case "$p" in
    */) ;;
    *) p="$p/" ;;
  esac
  path=${path//\\//}
  while [ "${path#/}" != "$path" ]; do path=${path#/}; done
  to_unix "$p$path"
}

# The secret-store helper's answer for user $2 on host $1: "OK <hex>",
# "NOTFOUND" or "ERROR <reason>".
secret_get() {
  local host=$1 user=$2 helpers out line
  helpers="$script_dir/../../../Scripts/ReaperPluginManager/helpers"
  if [ ! -d "$helpers" ]; then
    helpers="$(dirname "$data")/Scripts/ReaperPluginManager/Scripts/ReaperPluginManager/helpers"
  fi
  if [ "$platform" = windows ]; then
    local store="$data/secrets/$(to_hex "$SERVICE_PREFIX$host
$user").bin"
    [ -f "$helpers/rpm-secret.ps1" ] || { echo "ERROR rpm-secret.ps1 not found"; return; }
    out=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File "$(to_native "$helpers/rpm-secret.ps1")" -Action get -Store "$(to_native "$store")" 2>/dev/null)
  else
    [ -f "$helpers/rpm-secret.sh" ] || { echo "ERROR rpm-secret.sh not found"; return; }
    out=$(/bin/bash "$helpers/rpm-secret.sh" get "$SERVICE_PREFIX$host" "$user" 2>/dev/null)
  fi
  out=$(printf '%s' "$out" | tr -d '\r')
  while IFS= read -r line; do
    case "$line" in
      OK*|NOTFOUND|ERROR*) printf '%s\n' "$line"; return ;;
    esac
  done <<EOF
$out
EOF
  echo "ERROR no answer from the secret-store helper"
}

# Writes the netrc file for the configured server into the work folder and
# keeps the password in `secret` so error text can mask it.
open_credentials() {
  local answer hex fmt=
  [ -n "$user" ] && [ -n "$host" ] || return 0
  answer=$(secret_get "$host" "$user")
  case "$answer" in
    NOTFOUND) fail "$store_name: no password stored for user $user; run Setup." ;;
    ERROR*) fail "$store_name: ${answer#ERROR }" ;;
  esac
  hex=$(printf '%s' "${answer#OK}" | tr -d ' ')
  case "$hex" in
    ''|*[!0-9a-f]*) fail "$store_name: the stored password is empty or unreadable; run Setup." ;;
  esac
  while [ -n "$hex" ]; do
    fmt="$fmt\\x${hex:0:2}"
    hex=${hex:2}
  done
  printf -v secret "$fmt"
  netrc="$work/netrc"
  (umask 077; printf 'machine %s\nlogin %s\npassword %s\n' "$host" "$user" "$secret" > "$netrc") \
    || fail "cannot write the credentials file"
}

# The one-line reason for a failed curl run, from its exit code $1 and the
# error output in file $2, the password masked.
curl_reason() {
  local code=$1 detail reason status
  detail=$(tr -d '\r' < "$2" 2>/dev/null | sed -n 's/^curl: ([0-9]*) *//p' | tail -n 1)
  case "$code" in
    22)
      status=$(printf '%s' "$detail" | sed -n 's/.*\([0-9][0-9][0-9]\).*/\1/p')
      case "$status" in
        401) reason="Login failed: check the user name and password" ;;
        403) reason="Permission denied on the server" ;;
        404) reason="Not found on the server" ;;
        '') reason="The server answered with an HTTP error" ;;
        *) reason="The server answered with HTTP error $status" ;;
      esac
      ;;
    6) reason="Cannot find the server: its host name does not resolve" ;;
    7) reason="The server is unreachable" ;;
    9|21) reason="The server refused the command: the file is missing or permission is denied" ;;
    28) reason="The transfer timed out" ;;
    35) reason="The TLS handshake with the server failed" ;;
    51|60) reason="The server's TLS certificate is not trusted" ;;
    64) reason="The server refused TLS" ;;
    67) reason="Login failed: check the user name and password" ;;
    78) reason="Not found on the server" ;;
    127) reason="curl was not found" ;;
    *) reason="The transfer failed" ;;
  esac
  reason="$reason (curl $code${detail:+: $detail})"
  if [ -n "$secret" ]; then
    reason=${reason//"$secret"/***}
  fi
  printf '%s' "$reason" | tr '\t\r\n' '   '
}

# Downloads server path $1 to local file $2. Prints the reason on failure.
download() {
  local server_path=$1 dest=$2 errfile="$work/curl-error" code src
  if [ "$kind" = file ]; then
    src=$(file_server_path "$url" "$server_path")
    [ -f "$src" ] || { echo "Not found on the server: $server_path"; return 1; }
    cp -- "$src" "$dest" 2>/dev/null || { echo "Cannot copy $src"; return 1; }
    return 0
  fi
  local opts="--fail --silent --show-error --location --ftp-pasv"
  set -- $opts --connect-timeout "$CONNECT_TIMEOUT" --speed-limit 1 --speed-time "$STALL_TIMEOUT"
  case "$tls" in
    required) set -- "$@" --ssl-reqd ;;
    try) set -- "$@" --ssl ;;
  esac
  [ "$insecure" = 1 ] && set -- "$@" --insecure
  [ -n "$netrc" ] && set -- "$@" --netrc-file "$(to_native "$netrc")"
  set -- "$@" --stderr "$(to_native "$errfile")" --output "$(to_native "$dest.part")" \
    "$url$(encode_path "$server_path")"
  "$curl_bin" "$@" >/dev/null 2>&1
  code=$?
  if [ $code -ne 0 ]; then
    curl_reason "$code" "$errfile"
    rm -f -- "$dest.part" "$errfile"
    return 1
  fi
  rm -f -- "$errfile"
  mv -f -- "$dest.part" "$dest" || { echo "Cannot write $dest"; return 1; }
}

has() {
  LC_ALL=C grep -a -q -F -e "$2" -- "$1" 2>/dev/null
}

# "<kind>\t<generator>" of the file $1, from its magic bytes and the marker
# strings each installer generator leaves in its output.
detect() {
  local f=$1 magic trailer
  magic=$(od -An -v -tx1 -N8 "$f" | tr -d ' \n')
  trailer=$(tail -c 512 "$f" | head -c 4 | od -An -v -tx1 | tr -d ' \n')
  case "$magic" in
    4d5a*)
      if has "$f" "Inno Setup Setup Data" || has "$f" "InnoSetupLdrWindow"; then
        printf 'exe\tinno\n'
      elif has "$f" "Nullsoft.NSIS" || has "$f" "NullsoftInst"; then
        printf 'exe\tnsis\n'
      elif has "$f" ".wixburn" || has "$f" "WixBundle"; then
        printf 'exe\twix-burn\n'
      elif has "$f" "InstallShield"; then
        printf 'exe\tinstallshield\n'
      else
        printf 'exe\tunknown\n'
      fi
      ;;
    d0cf11e0a1b11ae1)
      if has "$f" "Windows Installer XML" || has "$f" "WiX Toolset"; then
        printf 'msi\twix\n'
      elif has "$f" "InstallShield"; then
        printf 'msi\tinstallshield\n'
      else
        printf 'msi\tmsi\n'
      fi
      ;;
    504b0304*) printf 'zip\tnone\n' ;;
    78617221*) printf 'pkg\tnone\n' ;;
    *)
      if [ "$trailer" = 6b6f6c79 ]; then
        printf 'dmg\tnone\n'
      else
        printf 'unknown\tunknown\n'
      fi
      ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{ print tolower($1) }'
  else
    shasum -a 256 < "$1" | awk '{ print tolower($1) }'
  fi
}

cmd_datadir() {
  local d
  d=$(data_dir) || fail "this script works only on Windows (Git Bash) and macOS"
  to_native "$d"
}

cmd_clean() {
  local dir
  [ $# -eq 1 ] || usage
  dir=$(to_unix "$1")
  [ -d "$dir" ] || { echo "OK"; return 0; }
  [ -f "$dir/$MARKER" ] || fail "not a folder fetch-installer.sh made: $1"
  rm -rf -- "$dir" || fail "cannot delete $1"
  echo "OK"
}

cleanup() {
  [ -n "$netrc" ] && rm -f -- "$netrc"
  if [ -n "$work" ] && [ "$keep" != 1 ]; then
    rm -rf -- "$work"
  fi
}

cmd_fetch() {
  [ $# -ge 1 ] || usage
  local cfg settings server_path name dest reason n=0 failed=0 i=0

  data=$(data_dir) || fail "this script works only on Windows (Git Bash) and macOS"
  cfg="$data/config.ini"
  [ -f "$cfg" ] || fail "no settings at $(to_native "$cfg"); run Setup in REAPER first."
  settings=$(read_server_settings "$cfg")
  { IFS= read -r url; IFS= read -r user; IFS= read -r tls; IFS= read -r insecure; } <<EOF
$settings
EOF
  [ -n "$url" ] || fail "No server is configured; run Setup."
  case "$url" in */) ;; *) url="$url/" ;; esac
  tls=$(lower "$tls")
  case "$tls" in required|try|off) ;; *) tls=required ;; esac
  [ "$insecure" = 1 ] || insecure=0
  kind=$(url_kind "$url")
  [ -n "$kind" ] || fail "The server address is not supported: $url"
  host=$(url_host "$url")
  if [ "$platform" = windows ]; then
    store_name="Windows DPAPI"
    curl_bin=curl
    if [ -n "$SYSTEMROOT" ] && [ -x "$(to_unix "$SYSTEMROOT")/System32/curl.exe" ]; then
      curl_bin="$(to_unix "$SYSTEMROOT")/System32/curl.exe"
    fi
  else
    store_name="macOS Keychain"
    curl_bin=/usr/bin/curl
  fi

  local tmp=${TMPDIR:-/tmp}
  work=$(mktemp -d "${tmp%/}/rpm-fetch.XXXXXX") || fail "cannot create a temporary folder"
  : > "$work/$MARKER"
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  if [ "$kind" != file ]; then
    open_credentials
  fi

  local lines=
  for server_path in "$@"; do
    i=$((i + 1))
    name=${server_path//\\//}
    name=${name##*/}
    mkdir -p -- "$work/$i" || fail "cannot write to the temporary folder"
    dest="$work/$i/$name"
    if [ -z "$name" ]; then
      failed=$((failed + 1))
      lines="${lines}FAIL $server_path${TAB}Not a file path
"
    elif reason=$(download "$server_path" "$dest"); then
      n=$((n + 1))
      lines="${lines}OK $server_path${TAB}$(to_native "$dest")${TAB}$(wc -c < "$dest" | tr -d ' ')${TAB}$(sha256_of "$dest")${TAB}$(detect "$dest")
"
    else
      failed=$((failed + 1))
      lines="${lines}FAIL $server_path${TAB}$reason
"
    fi
  done

  [ -n "$netrc" ] && rm -f -- "$netrc"
  netrc=
  if [ $n -gt 0 ]; then
    keep=1
    echo "DIR $(to_native "$work")"
  fi
  printf '%s' "$lines"
  [ $failed -eq 0 ]
}

[ "$platform" != other ] || fail "this script works only on Windows (Git Bash) and macOS"

action=$1
[ $# -ge 1 ] && shift
case "$action" in
  datadir) [ $# -eq 0 ] || usage; cmd_datadir ;;
  fetch) cmd_fetch "$@" ;;
  clean) cmd_clean "$@" ;;
  *) usage ;;
esac
