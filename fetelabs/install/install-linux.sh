#!/usr/bin/env bash
# Install FeteLABS on Zorin OS, Ubuntu or Debian, removing an old Odoo first.
#
#   bash install-linux.sh                 remove Odoo (asks first), then install
#   bash install-linux.sh --keep-odoo     install only, leave any Odoo alone
#   bash install-linux.sh --yes           answer yes to every question
#   bash install-linux.sh --source DIR    install from a local FeteLABS folder
#                                         instead of downloading it
#
# Run it as yourself (not with sudo); it asks for your password when it
# needs it. Nothing is deleted without a backup and a question first.
#
# What it sets up:
#   /opt/fetelabs/src          the program
#   /opt/fetelabs/venv         its Python packages
#   /etc/fetelabs/fetelabs.conf
#   /var/lib/fetelabs          uploaded files and sessions
#   fetelabs.service           starts with the computer
#   "FeteLABS" in the app menu, with the Fete Labs icon
set -euo pipefail

REPO="${FETELABS_REPO:-https://github.com/FetePass/odoo.git}"
BRANCH="${FETELABS_BRANCH:-fetelabs-19.0}"
PREFIX=/opt/fetelabs
CONF_DIR=/etc/fetelabs
CONF="$CONF_DIR/fetelabs.conf"
DATA=/var/lib/fetelabs
SVC_USER=fetelabs
PORT="${FETELABS_PORT:-8069}"
WKHTML_DEB="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb"

ASSUME_YES=0
REMOVE_ODOO=1
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --keep-odoo) REMOVE_ODOO=0 ;;
    --source) SOURCE="$(cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
  echo "Run this as your own user, not as root. It uses sudo when it needs to." >&2
  exit 1
fi
ME="${SUDO_USER:-$USER}"
MY_HOME="$(getent passwd "$ME" | cut -d: -f6)"
STAMP="$(date +%Y%m%d-%H%M)"
BACKUP="$MY_HOME/odoo-backup-$STAMP"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ask()  {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "    $* [y/N] " reply </dev/tty || true
  [[ "$reply" =~ ^[Yy] ]]
}
backup_dir() { mkdir -p "$BACKUP"; }
pg() { sudo -u postgres psql -X -q -At "$@"; }

# ---------------------------------------------------------------- old Odoo

remove_odoo() {
  say "Looking for an Odoo installed from source"

  # 1. Anything running.
  local procs
  procs="$(pgrep -af 'odoo-bin|openerp-server|odoo\.py' | grep -v "$PREFIX/" | grep -v pgrep || true)"
  if [ -n "$procs" ]; then
    note "Running now:"; printf '%s\n' "$procs" | sed 's/^/      /'
    if ask "Stop these?"; then
      printf '%s\n' "$procs" | awk '{print $1}' | xargs -r sudo kill
      sleep 3
    fi
  else
    note "No Odoo is running."
  fi

  # 2. Services that start it.
  # Read the unit folders directly as well as asking systemd, so a unit is
  # found even when systemd is not the one answering.
  local path unit
  while IFS= read -r path; do
    unit="$(basename "$path")"
    if ask "Stop, disable and delete the service $unit ($path)?"; then
      sudo systemctl disable --now "$unit" >/dev/null 2>&1 || true
      backup_dir; cp "$path" "$BACKUP/"; sudo rm -f "$path"
      sudo systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  done < <(find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -maxdepth 1 \
             \( -iname 'odoo*.service' -o -iname 'openerp*.service' \) -type f 2>/dev/null | sort -u)

  # 3. Databases. Postgres stays: FeteLABS uses it too.
  if command -v pg_lsclusters >/dev/null 2>&1; then
    sudo systemctl start postgresql >/dev/null 2>&1 || sudo service postgresql start >/dev/null 2>&1 || true
  fi
  if command -v psql >/dev/null 2>&1 && sudo -u postgres true 2>/dev/null && pg -c 'select 1' >/dev/null 2>&1; then
    local db dbs=""
    for db in $(pg -c "select datname from pg_database where not datistemplate and datname <> 'postgres' and pg_get_userbyid(datdba) <> '$SVC_USER'"); do
      if [ "$(pg -d "$db" -c "select 1 from pg_class where relname = 'ir_module_module' limit 1" 2>/dev/null)" = "1" ]; then
        dbs="$dbs $db"
      fi
    done
    if [ -n "$dbs" ]; then
      note "Odoo databases:$dbs"
      backup_dir
      for db in $dbs; do
        note "Backing up $db to $BACKUP/$db.dump"
        sudo -u postgres pg_dump -Fc "$db" | tee "$BACKUP/$db.dump" >/dev/null
      done
      if ask "Delete these databases now that they are backed up?"; then
        for db in $dbs; do sudo -u postgres dropdb --if-exists "$db"; done
      fi
    else
      note "No Odoo databases found."
    fi
  fi

  # 4. Uploaded files and settings.
  local f
  for f in "$MY_HOME/.local/share/Odoo" /var/lib/odoo; do
    if [ -d "$f" ]; then
      backup_dir
      note "Backing up $f"
      sudo tar -czf "$BACKUP/$(basename "$f")-files.tar.gz" -C "$(dirname "$f")" "$(basename "$f")"
      if ask "Delete $f?"; then sudo rm -rf "$f"; fi
    fi
  done
  for f in "$MY_HOME/.odoorc" "$MY_HOME/.openerp_serverrc" /etc/odoo; do
    if [ -e "$f" ]; then
      backup_dir; sudo cp -r "$f" "$BACKUP/"
      if ask "Delete $f?"; then sudo rm -rf "$f"; fi
    fi
  done

  # 5. The source folders themselves.
  local bin dir
  while IFS= read -r bin; do
    dir="$(dirname "$bin")"
    if [[ "$dir" == "$PREFIX"* ]] || { [ -n "$SOURCE" ] && [[ "$dir" == "$SOURCE"* ]]; }; then
      continue  # FeteLABS itself, not the Odoo being removed
    fi
    note "Odoo source folder: $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"
    if ask "Delete $dir?"; then sudo rm -rf "$dir"; fi
  done < <(find "$MY_HOME" /opt /srv /usr/local -maxdepth 5 -name odoo-bin -type f 2>/dev/null)

  if [ -d "$BACKUP" ]; then
    sudo chown -R "$ME": "$BACKUP"
    note "Backups are in $BACKUP"
  fi
}

# ---------------------------------------------------------------- FeteLABS

install_packages() {
  say "Installing what FeteLABS needs from the system"
  sudo apt-get update -qq
  sudo apt-get install -y -qq git curl ca-certificates python3 python3-venv python3-dev \
    build-essential libpq-dev libldap2-dev libsasl2-dev libxml2-dev libxslt1-dev \
    libjpeg-dev zlib1g-dev libffi-dev libssl-dev postgresql xdg-utils fontconfig >/dev/null

  local py
  py="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  python3 -c 'import sys; sys.exit(not ((3,10) <= sys.version_info[:2] <= (3,14)))' \
    || { echo "FeteLABS needs Python 3.10 to 3.14; this system has $py." >&2; exit 1; }

  # PDFs (invoices, receipts, tickets) need wkhtmltopdf. The build Odoo
  # recommends first; the distribution's if that cannot be installed.
  if ! command -v wkhtmltopdf >/dev/null 2>&1; then
    local deb=/tmp/wkhtmltox.deb
    if [ "$(dpkg --print-architecture)" = amd64 ] && curl -fsSL -o "$deb" "$WKHTML_DEB" \
       && sudo apt-get install -y -qq "$deb" >/dev/null 2>&1; then
      note "wkhtmltopdf 0.12.6 installed"
    else
      sudo apt-get install -y -qq wkhtmltopdf >/dev/null && note "wkhtmltopdf installed from the distribution"
    fi
    rm -f "$deb"
  fi
}

install_program() {
  say "Getting FeteLABS"
  sudo mkdir -p "$PREFIX"
  if [ -n "$SOURCE" ]; then
    sudo rm -rf "$PREFIX/src"
    sudo cp -a "$SOURCE" "$PREFIX/src"
  elif [ -d "$PREFIX/src/.git" ]; then
    sudo git -C "$PREFIX/src" fetch --depth 1 origin "$BRANCH"
    sudo git -C "$PREFIX/src" reset --hard FETCH_HEAD
  else
    sudo git clone --depth 1 --branch "$BRANCH" "$REPO" "$PREFIX/src"
  fi
  [ -f "$PREFIX/src/addons/fetelabs_branding/__manifest__.py" ] \
    || { echo "$PREFIX/src is not FeteLABS (no fetelabs_branding addon)." >&2; exit 1; }

  say "Installing its Python packages (a few minutes)"
  [ -x "$PREFIX/venv/bin/python" ] || sudo python3 -m venv "$PREFIX/venv"
  sudo "$PREFIX/venv/bin/pip" install -q --upgrade pip wheel
  sudo "$PREFIX/venv/bin/pip" install -q -r "$PREFIX/src/requirements.txt" phonenumbers
}

configure() {
  say "Setting up the database account and the service"
  sudo systemctl enable --now postgresql >/dev/null 2>&1 || sudo service postgresql start
  id "$SVC_USER" >/dev/null 2>&1 || sudo useradd --system --home "$DATA" --shell /usr/sbin/nologin "$SVC_USER"
  sudo mkdir -p "$DATA" "$CONF_DIR"
  sudo chown "$SVC_USER": "$DATA"
  if [ "$(pg -c "select 1 from pg_roles where rolname = '$SVC_USER'")" != "1" ]; then
    sudo -u postgres createuser --createdb "$SVC_USER"
  fi

  if [ ! -f "$CONF" ]; then
    MASTER="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    sudo tee "$CONF" >/dev/null <<EOF
[options]
; The password the database manager asks for when you create, copy or
; delete a company database. Keep it somewhere safe.
admin_passwd = $MASTER
db_host = False
db_user = $SVC_USER
addons_path = $PREFIX/src/addons,$PREFIX/src/odoo/addons
data_dir = $DATA
http_interface = 127.0.0.1
http_port = $PORT
list_db = True
without_demo = True
EOF
    sudo chown root:"$SVC_USER" "$CONF"
    sudo chmod 640 "$CONF"
    printf 'FeteLABS master password: %s\n(also in %s)\n' "$MASTER" "$CONF" > "$MY_HOME/FeteLABS-master-password.txt"
    sudo chown "$ME": "$MY_HOME/FeteLABS-master-password.txt"
    chmod 600 "$MY_HOME/FeteLABS-master-password.txt"
  fi

  sudo tee /etc/systemd/system/fetelabs.service >/dev/null <<EOF
[Unit]
Description=FeteLABS
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
ExecStart=$PREFIX/venv/bin/python $PREFIX/src/odoo-bin -c $CONF
Restart=on-failure
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

  # The app menu entry, with the Fete Labs icon.
  sudo install -D -m 644 "$PREFIX/src/fetelabs/brand/fetelabs-512.png" /usr/share/icons/hicolor/512x512/apps/fetelabs.png
  sudo tee /usr/share/applications/fetelabs.desktop >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=FeteLABS
Comment=Run your Caribbean business
Exec=xdg-open http://localhost:$PORT
Icon=fetelabs
Terminal=false
Categories=Office;Finance;
EOF
  sudo gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
  sudo update-desktop-database -q /usr/share/applications 2>/dev/null || true
}

start() {
  say "Starting FeteLABS"
  if [ -d /run/systemd/system ]; then
    sudo systemctl daemon-reload
    sudo systemctl enable --now fetelabs.service
    sudo systemctl restart fetelabs.service
  else
    note "No systemd here; starting it in the background instead."
    sudo -u "$SVC_USER" nohup "$PREFIX/venv/bin/python" "$PREFIX/src/odoo-bin" -c "$CONF" \
      >"/tmp/fetelabs.log" 2>&1 &
  fi

  for _ in $(seq 1 90); do
    if curl -fs -o /dev/null --noproxy '*' "http://localhost:$PORT/web/database/selector"; then
      break
    fi
    sleep 2
  done
  curl -fs -o /dev/null --noproxy '*' "http://localhost:$PORT/web/database/selector" \
    || { echo "FeteLABS did not answer. Look at: sudo journalctl -u fetelabs -n 50" >&2; exit 1; }
}

if [ "$REMOVE_ODOO" -eq 1 ]; then remove_odoo; fi
install_packages
install_program
configure
start

say "FeteLABS is running at http://localhost:$PORT"
note "Open it from the app menu (FeteLABS) or that address."
note "First visit: create your company database. It asks for the master"
note "password, which is in $MY_HOME/FeteLABS-master-password.txt"
note "Pick your island as the country, so it sets up the right taxes."
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  sudo -u "$ME" xdg-open "http://localhost:$PORT/web/database/manager" >/dev/null 2>&1 || true
fi
