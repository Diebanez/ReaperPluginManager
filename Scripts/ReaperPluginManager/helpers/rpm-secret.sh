#!/bin/bash
# rpm-secret.sh: macOS secret-store back end of ReaperPluginManager.
# Keeps generic-password items in the user's default Keychain through the
# `security` tool, keyed by service and account. Targets bash 3.2.
#
#   rpm-secret.sh get    <service> <account>          prints "OK <hex>" or "NOTFOUND"
#   rpm-secret.sh exists <service> <account>          prints "OK" or "NOTFOUND"
#   rpm-secret.sh copy   <service> <account>          prints "OK" or "NOTFOUND"
#   rpm-secret.sh set    <service> <account> <infile> prints "OK"
#   rpm-secret.sh delete <service> <account>          prints "OK", also when absent
#
# Any failure prints "ERROR <reason>". set reads the secret from <infile>,
# which is deleted whatever happens; get prints it as lowercase hex; copy
# pipes it from `security ... -w` to `pbcopy` and prints nothing of it. The
# secret never reaches a command line: it is written through `security -i`,
# which reads its command, the password as -X hex included, from stdin.
# Exit codes: 0 OK, 1 ERROR, 2 NOTFOUND.

action=$1
service=$2
account=$3
infile=$4

fail() {
  echo "ERROR $1"
  exit 1
}

to_hex() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

case "$action" in
  get|exists|copy|set|delete) ;;
  *)
    [ -n "$infile" ] && rm -f -- "$infile"
    fail "unknown action: $action"
    ;;
esac

if [ "$action" = "set" ]; then
  [ -n "$infile" ] || fail "no input file given"
  secret=
  if [ -f "$infile" ]; then
    IFS= read -r secret < "$infile"
  fi
  rm -f -- "$infile"
fi

[ -n "$service" ] || fail "no service given"
[ -n "$account" ] || fail "no account given"
case "$service$account" in
  *\"*|*\\*) fail "service and account cannot contain quotes or backslashes" ;;
esac

case "$action" in
  get)
    secret=$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)
    rc=$?
    if [ $rc -eq 44 ]; then
      echo "NOTFOUND"
      exit 2
    fi
    [ $rc -eq 0 ] || fail "security find-generic-password exited with code $rc"
    echo "OK $(to_hex "$secret")"
    ;;
  exists|copy)
    security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 44 ]; then
      echo "NOTFOUND"
      exit 2
    fi
    [ $rc -eq 0 ] || fail "security find-generic-password exited with code $rc"
    if [ "$action" = "copy" ]; then
      security find-generic-password -s "$service" -a "$account" -w 2>/dev/null \
        | tr -d '\n' | pbcopy
      status=("${PIPESTATUS[@]}")
      [ "${status[0]}" -eq 0 ] || fail "security find-generic-password exited with code ${status[0]}"
      [ "${status[2]}" -eq 0 ] || fail "pbcopy exited with code ${status[2]}"
    fi
    echo "OK"
    ;;
  set)
    [ -n "$secret" ] || fail "empty secret"
    hex=$(to_hex "$secret")
    printf 'add-generic-password -U -s "%s" -a "%s" -X %s\n' "$service" "$account" "$hex" \
      | security -i >/dev/null 2>&1
    stored=$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null) \
      || fail "the Keychain item was not written"
    [ "$stored" = "$secret" ] || fail "the Keychain item does not hold the new secret"
    echo "OK"
    ;;
  delete)
    security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1
    rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 44 ] || fail "security delete-generic-password exited with code $rc"
    echo "OK"
    ;;
esac
exit 0
