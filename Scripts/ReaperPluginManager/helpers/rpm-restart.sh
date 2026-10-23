#!/bin/bash
# rpm-restart.sh: macOS restart helper of ReaperPluginManager.
# Waits for REAPER to quit, then starts it again. Targets bash 3.2.
#
#   rpm-restart.sh <REAPER app bundle>
#
# Every 0.5 s it looks for a running process whose command starts with an
# executable inside the bundle (<bundle>/Contents/MacOS/), so another REAPER
# installation running at the same time neither blocks nor triggers the
# restart. Once none is left it runs open on the bundle and exits; when one is
# still running after 60 s it exits without starting anything. It writes no
# output and no file.

exec >/dev/null 2>&1

bundle=$1
[ -n "$bundle" ] || exit 1
while [ "$bundle" != / ] && [ "${bundle%/}" != "$bundle" ]; do
  bundle=${bundle%/}
done
[ -d "$bundle" ] || exit 1
prefix=$bundle/Contents/MacOS/

running() {
  local line
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      "$prefix"*) return 0 ;;
    esac
  done < <(ps -axo command=)
  return 1
}

start=$SECONDS
while running; do
  [ $((SECONDS - start)) -ge 60 ] && exit 1
  sleep 0.5
done
open "$bundle"
exit 0
