#!/usr/bin/env bash
# ReaperPluginManager catalogue server: HTTPS + WebDAV on nginx, a Let's
# Encrypt certificate, one write account (maint) for the maintainer and one
# read-only account per member. For Ubuntu 22.04 or later and Debian 12 or
# later; the guide is server/README.md.
#
#   sudo bash rpm-server.sh setup DOMAIN [member ...]  install and configure, create accounts
#   sudo bash rpm-server.sh add-member NAME            new read-only account (prints its password)
#   sudo bash rpm-server.sh remove-member NAME         remove a read-only account
#   sudo bash rpm-server.sh reset NAME                 new password for an account (prints it)
#   sudo bash rpm-server.sh list                       list the accounts
#   sudo bash rpm-server.sh import DIR                 move installers from DIR into the catalogue
#                                                      folder, keeping their relative paths
#
# Catalogue URL: https://DOMAIN/rpm/   files on disk: /srv/rpm/
# Adds one nginx site and leaves every other site untouched.
set -euo pipefail

CONF=/etc/rpm-server.conf
ROOT=/srv/rpm
ACME=/var/www/rpm-acme
BODY=/var/lib/nginx/rpm-body
SITE=/etc/nginx/sites-available/rpm
READERS=/etc/nginx/rpm-readers.htpasswd
WRITERS=/etc/nginx/rpm-writers.htpasswd
MAINT=maint
DOMAIN=

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

# tr reads a bounded input to its end: cutting an endless stream with head
# would kill tr with SIGPIPE, which pipefail and set -e turn into a silent exit.
new_password() {
  local p
  p=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
  echo "${p:0:24}"
}

valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{1,31}$ ]] || die "invalid user name '$1' (lowercase letters, digits, - and _)"; }

valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || die "invalid domain '$1'"; }

# Sets $1's password in htpasswd file $2 (bcrypt), creating the file.
set_user() {
  local user=$1 file=$2 pass=$3
  [ -f "$file" ] || install -m 640 -o root -g www-data /dev/null "$file"
  htpasswd -B -b "$file" "$user" "$pass" >/dev/null 2>&1
}

http_site() {
  cat >"$SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    server_tokens off;
    location /.well-known/acme-challenge/ { root $ACME; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
}

https_site() {
  local cert=/etc/letsencrypt/live/$DOMAIN
  http_site
  cat >>"$SITE" <<EOF

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    server_tokens off;
    ssl_certificate $cert/fullchain.pem;
    ssl_certificate_key $cert/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / { return 404; }

    # Everyone with an account reads; only the write accounts upload, rename
    # (MOVE) and delete.
    location /rpm/ {
        root /srv;
        autoindex off;
        auth_basic "ReaperPluginManager";
        auth_basic_user_file $READERS;
        limit_except GET HEAD {
            auth_basic "ReaperPluginManager (write)";
            auth_basic_user_file $WRITERS;
        }
        dav_methods PUT DELETE MOVE;
        create_full_put_path on;
        dav_access user:rw group:r all:r;
        client_max_body_size 0;
        client_body_temp_path $BODY;
        client_body_timeout 300s;
        send_timeout 300s;
    }
}
EOF
}

reload_nginx() { nginx -t && systemctl reload nginx; }

# Exercises the server the way RPM does: write as maint, read as a member,
# and check that a member cannot write.
self_test() {
  local member=$1 member_pass=$2 maint_pass=$3 base="https://$DOMAIN/rpm" tmp code
  tmp=$(mktemp)
  echo "rpm self-test $(date -u +%FT%TZ)" >"$tmp"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/manifest.json")
  [ "$code" = 401 ] || die "self-test: anonymous read gave HTTP $code, expected 401"
  curl -sSf -o /dev/null -u "$MAINT:$maint_pass" --upload-file "$tmp" "$base/selftest/a.txt.uploading"
  curl -sSf -o /dev/null -u "$MAINT:$maint_pass" --request MOVE \
    --header "Destination: $base/selftest/a.txt" --header "Overwrite: T" "$base/selftest/a.txt.uploading"
  curl -sSf -u "$member:$member_pass" "$base/selftest/a.txt" | cmp -s - "$tmp" || die "self-test: member read back different content"
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$member:$member_pass" --upload-file "$tmp" "$base/selftest/b.txt")
  [ "$code" = 401 ] || die "self-test: member write gave HTTP $code, expected 401"
  curl -sSf -o /dev/null -u "$MAINT:$maint_pass" --request DELETE "$base/selftest/a.txt"
  rm -f "$tmp"
  rmdir "$ROOT/selftest" 2>/dev/null || true
  echo "self-test passed: anonymous refused, maint wrote/renamed/deleted, member read and could not write"
}

cmd_setup() {
  local domain=${1:-} m
  [ -n "$domain" ] || die "usage: setup DOMAIN [member ...]"
  shift
  valid_domain "$domain"
  [ -z "$DOMAIN" ] || [ "$DOMAIN" = "$domain" ] || die "this server is set up for $DOMAIN; remove $CONF to move it to $domain"
  DOMAIN=$domain
  local members=("$@")
  for m in "${members[@]}"; do valid_name "$m"; [ "$m" != "$MAINT" ] || die "'$MAINT' is the write account"; done

  echo "== packages"
  apt-get update -qq
  apt-get install -y -qq nginx certbot apache2-utils curl >/dev/null
  echo "DOMAIN=$DOMAIN" >"$CONF"

  echo "== folders"
  install -d -m 755 -o www-data -g www-data "$ROOT" "$BODY"
  install -d -m 755 "$ACME"

  echo "== firewall"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && echo "ufw: opened 80/tcp and 443/tcp"
  else
    echo "ufw inactive: nothing to open"
  fi

  echo "== certificate"
  if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    http_site
    ln -sf "$SITE" /etc/nginx/sites-enabled/rpm
    reload_nginx
    certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --deploy-hook "systemctl reload nginx"
  else
    echo "already present: /etc/letsencrypt/live/$DOMAIN"
  fi

  echo "== nginx"
  https_site
  ln -sf "$SITE" /etc/nginx/sites-enabled/rpm
  reload_nginx

  echo "== accounts"
  local maint_pass first_member="" first_pass="" out=()
  if grep -q "^$MAINT:" "$WRITERS" 2>/dev/null; then
    echo "$MAINT exists: password unchanged"
    maint_pass=""
  else
    maint_pass=$(new_password)
    set_user "$MAINT" "$WRITERS" "$maint_pass"
    set_user "$MAINT" "$READERS" "$maint_pass"
    out+=("$MAINT (write)  $maint_pass")
  fi
  for m in "${members[@]}"; do
    if grep -q "^$m:" "$READERS" 2>/dev/null; then
      echo "$m exists: password unchanged"
      continue
    fi
    local p; p=$(new_password)
    set_user "$m" "$READERS" "$p"
    out+=("$m (read)  $p")
    [ -n "$first_member" ] || { first_member=$m; first_pass=$p; }
  done

  echo "== self-test"
  if [ -n "$maint_pass" ] && [ -n "$first_member" ]; then
    self_test "$first_member" "$first_pass" "$maint_pass"
  else
    echo "skipped: needs a new maint password and a new member in this run"
  fi

  echo
  echo "Catalogue URL: https://$DOMAIN/rpm/"
  if [ ${#out[@]} -gt 0 ]; then
    echo "New accounts (shown once, not stored in clear anywhere):"
    printf '  %s\n' "${out[@]}"
  fi
}

cmd_add_member() {
  local m=${1:-}; [ -n "$m" ] || die "usage: add-member NAME"
  valid_name "$m"; [ "$m" != "$MAINT" ] || die "'$MAINT' is the write account"
  grep -q "^$m:" "$READERS" 2>/dev/null && die "$m already exists"
  local p; p=$(new_password)
  set_user "$m" "$READERS" "$p"
  echo "$m (read)  $p"
}

cmd_remove_member() {
  local m=${1:-}; [ -n "$m" ] || die "usage: remove-member NAME"
  [ "$m" != "$MAINT" ] || die "refusing to remove the write account"
  htpasswd -D "$READERS" "$m" >/dev/null 2>&1 || die "no account $m"
  echo "removed $m"
}

cmd_reset() {
  local m=${1:-}; [ -n "$m" ] || die "usage: reset NAME"
  grep -q "^$m:" "$READERS" 2>/dev/null || die "no account $m"
  local p; p=$(new_password)
  set_user "$m" "$READERS" "$p"
  [ "$m" != "$MAINT" ] || set_user "$m" "$WRITERS" "$p"
  echo "$m  $p"
}

cmd_list() {
  echo "write: $(cut -d: -f1 "$WRITERS" 2>/dev/null | paste -sd' ')"
  echo "read:  $(cut -d: -f1 "$READERS" 2>/dev/null | grep -vx "$MAINT" | paste -sd' ')"
}

# Moves every file under $1 to the same relative path under $ROOT, owned by
# the web server, and prints each one's server path and SHA-256. An existing
# file of the same path is never overwritten.
cmd_import() {
  local src=${1:-} f rel dst n=0
  [ -n "$src" ] && [ -d "$src" ] || die "usage: import DIR"
  src=$(cd "$src" && pwd)
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    [[ $rel != *..* && $rel != manifest.json* ]] || die "refusing $rel"
    dst=$ROOT/$rel
    [ ! -e "$dst" ] || die "already on the server: $rel (remove it first)"
    install -d -m 755 -o www-data -g www-data "$(dirname "$dst")"
    install -m 644 -o www-data -g www-data "$f" "$dst"
    rm -f "$f"
    printf '%s  %s\n' "$(sha256sum "$dst" | cut -d' ' -f1)" "$rel"
    n=$((n + 1))
  done < <(find "$src" -type f -print0 | sort -z)
  find "$src" -mindepth 1 -type d -empty -delete
  echo "imported $n file(s) into $ROOT"
}

case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  import) shift; cmd_import "$@" ;;
  add-member) shift; cmd_add_member "$@" ;;
  remove-member) shift; cmd_remove_member "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  list) cmd_list ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
