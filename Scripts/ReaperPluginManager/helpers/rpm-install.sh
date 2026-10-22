#!/bin/bash
# rpm-install.sh: macOS install helper of ReaperPluginManager.
# Downloads, verifies and installs the plugins of one job file, appending
# every step to the status file per the helper contract of the
# plugin-installation feature. Targets bash 3.2: no associative arrays,
# mapfile or ${var,,}.
#
#   rpm-install.sh --job <file> --status <file> --workdir <dir>
#                  [--netrc <file>] [--tls required|try|off] [--insecure]
#                  [--plugins-root <dir>]
#
# --plugins-root defaults to ~/Library/Audio/Plug-Ins. Status lines:
# START <n>, ITEM <id> download|verify|install, OK <id>, FAIL <id> <message>,
# DONE <ok> <failed>. The credentials file is deleted when the run ends.
# Where ditto and xattr are missing (development runs under Git Bash), unzip
# and cp -R stand in and the quarantine flag is left alone.

job=
status=
workdir=
netrc=
tls=required
insecure=0
plugins_root="$HOME/Library/Audio/Plug-Ins"

while [ $# -gt 0 ]; do
  case "$1" in
    --job) job=$2 ;;
    --status) status=$2 ;;
    --workdir) workdir=$2 ;;
    --netrc) netrc=$2 ;;
    --tls) tls=$2 ;;
    --plugins-root) plugins_root=$2 ;;
    --insecure) insecure=1; shift; continue ;;
    *) shift; continue ;;
  esac
  shift 2 2>/dev/null || shift
done

cleanup() {
  [ -n "$netrc" ] && rm -f -- "$netrc"
}
trap cleanup EXIT

[ -n "$status" ] || exit 1
workdir=${workdir%/}
plugins_root=${plugins_root%/}

say() {
  printf '%s\n' "$*" >> "$status"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# The text $1 on one line: CR, LF and tabs become spaces, ends trimmed.
one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/^ *//; s/ *$//'
}

# Percent-decodes $1; literal backslashes are kept as they are.
url_decode() {
  printf '%b' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# The download's file name: the last URL segment of $1, decoded.
file_name() {
  local seg=${1%%\?*}
  seg=${seg%%#*}
  seg=$(url_decode "${seg##*/}")
  case "$seg" in
    ''|.|..|*/*) seg=installer ;;
  esac
  printf '%s' "$seg"
}

curl_opts=(--fail --silent --show-error --location --ftp-pasv
  --connect-timeout 30 --speed-limit 1 --speed-time 60)
case "$tls" in
  required) curl_opts+=(--ssl-reqd) ;;
  try) curl_opts+=(--ssl) ;;
esac
[ "$insecure" = 1 ] && curl_opts+=(--insecure)
[ -n "$netrc" ] && curl_opts+=(--netrc-file "$netrc")

# Job lines: id name type url sha256 args dest. Tabs become \037 so that
# empty fields survive the read.
ids=()
types=()
urls=()
shas=()
dests=()
n=0
if [ -n "$job" ] && [ -f "$job" ]; then
  while IFS=$'\037' read -r f_id f_name f_type f_url f_sha f_args f_dest || [ -n "$f_id" ]; do
    f_dest=${f_dest%$'\r'}
    if [ -n "$f_id" ]; then
      ids[n]=$f_id
      types[n]=$f_type
      urls[n]=$f_url
      shas[n]=$f_sha
      dests[n]=$f_dest
      n=$((n + 1))
    fi
    f_id=
  done < <(tr '\t' '\037' < "$job")
fi

# Copies the plugin item $1 to its destination folder, chosen by the entry's
# dest $2 or else by the item's extension, replacing an item of the same name,
# then clears the quarantine flag on the copy. Sets msg on failure.
route_item() {
  local item=$1 dest=$2 base folder target err rc
  base=${item##*/}
  if [ -n "$dest" ]; then
    case "$(lower "$dest")" in
      vst3) folder=$plugins_root/VST3 ;;
      vst2) folder=$plugins_root/VST ;;
      au) folder=$plugins_root/Components ;;
      clap) folder=$plugins_root/CLAP ;;
      *) folder=${dest%/} ;;
    esac
  else
    case "$(lower "${base##*.}")" in
      vst3) folder=$plugins_root/VST3 ;;
      component) folder=$plugins_root/Components ;;
      vst) folder=$plugins_root/VST ;;
      clap) folder=$plugins_root/CLAP ;;
    esac
  fi
  target=$folder/$base
  if ! mkdir -p -- "$folder" 2>/dev/null; then
    msg="cannot create the folder $folder"
    return 1
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! rm -rf -- "$target" 2>/dev/null; then
      msg="cannot replace $target"
      return 1
    fi
  fi
  if have ditto; then
    err=$(ditto "$item" "$target" 2>&1)
  else
    err=$(cp -R "$item" "$target" 2>&1)
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    msg="cannot copy $base to $folder: $(one_line "$err")"
    return 1
  fi
  if have xattr; then
    xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1
  fi
  return 0
}

# Unpacks the zip $1 into the work folder $2 and routes every outermost
# plugin item, without descending into one and ignoring __MACOSX. Sets msg
# on failure.
install_zip() {
  local archive=$1 out=$2/unpacked dest=$3 err rc item found=0
  rm -rf -- "$out"
  if ! mkdir -p -- "$out" 2>/dev/null; then
    msg="cannot create the folder $out"
    return 1
  fi
  if have ditto; then
    err=$(ditto -x -k "$archive" "$out" 2>&1)
  else
    err=$(unzip -q -o "$archive" -d "$out" 2>&1)
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    msg="cannot unpack the archive: $(one_line "$err")"
    return 1
  fi
  while IFS= read -r item; do
    found=$((found + 1))
    route_item "$item" "$dest" || return 1
  done < <(find "$out" -mindepth 1 \( -name __MACOSX -prune \) -o \
    \( \( -iname '*.vst3' -o -iname '*.component' -o -iname '*.vst' -o -iname '*.clap' \) \
    -print -prune \))
  if [ $found -eq 0 ]; then
    msg="no plugin (.vst3, .component, .vst, .clap) in the archive"
    return 1
  fi
  return 0
}

# Downloads, verifies and installs job entry $1, writing its ITEM lines.
# Sets msg on failure.
install_one() {
  local id=${ids[$1]} type=${types[$1]} url=${urls[$1]} dest=${dests[$1]}
  local sha dir file err rc actual
  sha=$(printf '%s' "${shas[$1]}" | tr -d ' ')
  say "ITEM $id download"
  if [ -z "$workdir" ]; then
    msg="no work folder given"
    return 1
  fi
  case "$id" in
    */*|.|..)
      msg="invalid plugin id"
      return 1
      ;;
  esac
  dir=$workdir/$id
  rm -rf -- "$dir"
  if ! mkdir -p -- "$dir" 2>/dev/null; then
    msg="cannot create the folder $dir"
    return 1
  fi
  file=$dir/$(file_name "$url")
  err=$(curl "${curl_opts[@]}" -o "$file" "$url" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    err=$(one_line "$err")
    err=${err#curl: }
    msg="download failed: ${err:-curl exit code $rc}"
    return 1
  fi

  if [ -n "$sha" ]; then
    say "ITEM $id verify"
    actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{ print $1 }')
    if [ -z "$actual" ]; then
      msg="cannot compute the checksum"
      return 1
    fi
    if [ "$(lower "$actual")" != "$(lower "$sha")" ]; then
      msg="checksum does not match (expected $sha, got $actual)"
      return 1
    fi
  fi

  say "ITEM $id install"
  case "$(lower "$type")" in
    zip) install_zip "$file" "$dir" "$dest" ;;
    *)
      msg="installer type not supported on macOS"
      return 1
      ;;
  esac
}

say "START $n"
ok=0
failed=0
i=0
while [ $i -lt $n ]; do
  msg=
  if install_one $i; then
    say "OK ${ids[i]}"
    ok=$((ok + 1))
    rm -rf -- "$workdir/${ids[i]}"
  else
    say "FAIL ${ids[i]} $(one_line "$msg")"
    failed=$((failed + 1))
  fi
  i=$((i + 1))
done

say "DONE $ok $failed"
cleanup
exit 0
