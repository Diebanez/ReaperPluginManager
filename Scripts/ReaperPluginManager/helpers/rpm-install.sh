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
# DONE <ok> <failed>. Packages (pkg entries, and a package found in a dmg)
# are queued and installed after every other entry in one administrator-
# privileged run, so the password is asked once; DONE follows that phase.
# The credentials file is deleted when the run ends.
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

# Routes every outermost plugin item under the folder $1 with the dest $2,
# without descending into one and ignoring __MACOSX; $3 names the source in
# the message when there is none. Sets msg on failure.
route_items() {
  local root=$1 dest=$2 what=$3 item found=0
  while IFS= read -r item; do
    found=$((found + 1))
    route_item "$item" "$dest" || return 1
  done < <(find "$root" -mindepth 1 \( -name __MACOSX -prune \) -o \
    \( \( -iname '*.vst3' -o -iname '*.component' -o -iname '*.vst' -o -iname '*.clap' \) \
    -print -prune \) 2>/dev/null)
  if [ $found -eq 0 ]; then
    msg="no plugin (.vst3, .component, .vst, .clap) in the $what"
    return 1
  fi
  return 0
}

# Unpacks the zip $1 into the work folder $2 and routes its plugin items with
# the dest $3. Sets msg on failure.
install_zip() {
  local archive=$1 out=$2/unpacked dest=$3 err rc
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
  route_items "$out" "$dest" "archive"
}

# The first package (.pkg, .mpkg) within two levels of the folder $1, the
# shallower first and in name order; uninstallers are skipped.
find_package() {
  local depth item
  for depth in 1 2; do
    while IFS= read -r item; do
      case "$(lower "${item##*/}")" in
        *uninstall*) continue ;;
      esac
      printf '%s' "$item"
      return 0
    done < <(find "$1" -mindepth $depth -maxdepth $depth \
      \( -iname '*.pkg' -o -iname '*.mpkg' \) -print 2>/dev/null | sort)
  done
  return 1
}

# Mounts the disk image $1 in the work folder $2. A package within two levels
# of the volume is copied into the work folder and named in pkg, returning 2
# so it is queued; otherwise the volume's plugin items are routed with the
# dest $3. The image is detached either way. Sets msg on failure.
install_dmg() {
  local image=$1 dir=$2 dest=$3 mnt=$2/volume err rc found
  if ! mkdir -p -- "$mnt" 2>/dev/null; then
    msg="cannot create the folder $mnt"
    return 1
  fi
  # yes accepts the licence agreement some images show before mounting.
  err=$(yes | hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$image" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    err=$(printf '%s\n' "$err" | sed '/^[[:space:]]*$/d' | tail -n 1)
    msg="cannot mount the disk image: $(one_line "${err:-hdiutil exit code $rc}")"
    return 1
  fi
  found=$(find_package "$mnt")
  if [ -n "$found" ]; then
    pkg=$dir/${found##*/}
    rm -rf -- "$pkg"
    if have ditto; then
      err=$(ditto "$found" "$pkg" 2>&1)
    else
      err=$(cp -R "$found" "$pkg" 2>&1)
    fi
    if [ $? -ne 0 ]; then
      msg="cannot copy the package ${found##*/}: $(one_line "$err")"
      rc=1
    else
      rc=2
    fi
  else
    route_items "$mnt" "$dest" "disk image"
    rc=$?
  fi
  hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1
  return $rc
}

# Downloads, verifies and installs job entry $1, writing its ITEM lines.
# Returns 0 when installed, 2 when its package is queued (named in pkg) and
# 1 on failure, setting msg.
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
    dmg) install_dmg "$file" "$dir" "$dest" ;;
    pkg)
      pkg=$file
      return 2
      ;;
    *)
      msg="installer type not supported on macOS"
      return 1
      ;;
  esac
}

# Installs the queued packages in one run of a generated script under
# administrator privileges, one password prompt for all of them. The script
# writes each package's OK or FAIL line; a package left without one fails
# with the reason the run did not reach it.
install_packages() {
  local script=$workdir/rpm-packages.sh before err rc reason j id got line
  {
    printf '#!/bin/bash\n'
    printf 'status=%q\n' "$status"
    cat <<'EOF'
run_pkg() {
  local err rc short
  err=$(/usr/sbin/installer -pkg "$2" -target / 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    printf 'OK %s\n' "$1" >> "$status"
    return
  fi
  short=$(printf '%s\n' "$err" | grep -i 'error')
  [ -n "$short" ] || short=$err
  short=$(printf '%s' "$short" | sed 's/^installer: //' | tr '\r\n\t' '   ' | sed 's/^ *//; s/ *$//')
  printf 'FAIL %s package installation failed: %s\n' "$1" "${short:-installer exit code $rc}" >> "$status"
}
EOF
    j=0
    while [ $j -lt ${#q_ids[@]} ]; do
      printf 'run_pkg %q %q\n' "${q_ids[j]}" "${q_pkgs[j]}"
      j=$((j + 1))
    done
  } > "$script" 2>/dev/null

  before=$(wc -l < "$status" | tr -d ' ')
  if [ -s "$script" ]; then
    err=$(osascript -e 'on run argv' \
      -e 'do shell script "/bin/bash " & quoted form of (item 1 of argv) with administrator privileges' \
      -e 'end run' "$script" 2>&1)
    rc=$?
  else
    err="cannot write the package script $script"
    rc=1
  fi
  rm -f -- "$script"
  # A cancelled password prompt is AppleScript error -128.
  if [ $rc -eq 0 ]; then
    reason="the package installer reported no outcome"
  else
    case "$err" in
      *-128*) reason="administrator password not entered" ;;
      *) reason="package installation did not run: $(one_line "${err:-osascript exit code $rc}")" ;;
    esac
  fi

  j=0
  while [ $j -lt ${#q_ids[@]} ]; do
    id=${q_ids[j]}
    got=
    while IFS= read -r line; do
      case "${line%$'\r'}" in
        "OK $id") got=ok ;;
        "FAIL $id "*) got=fail ;;
      esac
    done < <(tail -n +$((before + 1)) "$status")
    case "$got" in
      ok)
        ok=$((ok + 1))
        rm -rf -- "$workdir/$id"
        ;;
      fail) failed=$((failed + 1)) ;;
      *)
        say "FAIL $id $reason"
        failed=$((failed + 1))
        ;;
    esac
    j=$((j + 1))
  done
}

say "START $n"
ok=0
failed=0
q_ids=()
q_pkgs=()
i=0
while [ $i -lt $n ]; do
  msg=
  pkg=
  install_one $i
  case $? in
    0)
      say "OK ${ids[i]}"
      ok=$((ok + 1))
      rm -rf -- "$workdir/${ids[i]}"
      ;;
    2)
      q_ids+=("${ids[i]}")
      q_pkgs+=("$pkg")
      ;;
    *)
      say "FAIL ${ids[i]} $(one_line "$msg")"
      failed=$((failed + 1))
      ;;
  esac
  i=$((i + 1))
done

[ ${#q_ids[@]} -gt 0 ] && install_packages

say "DONE $ok $failed"
cleanup
exit 0
