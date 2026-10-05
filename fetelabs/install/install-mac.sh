#!/bin/bash
# Install FeteLABS on a Mac (macOS 12 or later, Apple Silicon or Intel),
# removing an old Odoo first if there is one.
#
# Open Terminal (Applications > Utilities) and run:
#
#   curl -fsSLO https://raw.githubusercontent.com/FetePass/odoo/fetelabs-19.0/fetelabs/install/install-mac.sh
#   bash install-mac.sh
#
# Options:
#   --keep-odoo     install only, leave any Odoo alone
#   --yes           answer yes to every question
#   --source DIR    install from a local FeteLABS folder instead of downloading it
#
# It installs Homebrew (the usual way to add developer tools to a Mac) if it
# is missing, then Python 3.12, PostgreSQL 16 and the tool that makes PDFs.
# It asks for your Mac password when it needs it. Nothing is deleted
# without a backup and a question first.
#
# What it sets up, all inside your home folder:
#   ~/FeteLABS/src            the program
#   ~/FeteLABS/venv           its Python packages
#   ~/FeteLABS/fetelabs.conf
#   ~/FeteLABS/data           uploaded files and sessions
#   ~/Applications/FeteLABS.app, with the Fete Labs icon
#   a background service that starts FeteLABS when you log in
#
# Written for the bash that ships with macOS (3.2): no arrays, no ${x,,}.
set -euo pipefail

REPO="${FETELABS_REPO:-https://github.com/FetePass/odoo.git}"
BRANCH="${FETELABS_BRANCH:-fetelabs-19.0}"
ROOT="$HOME/FeteLABS"
SRC="$ROOT/src"
VENV="$ROOT/venv"
CONF="$ROOT/fetelabs.conf"
DATA="$ROOT/data"
PORT="${FETELABS_PORT:-8069}"
LABEL="ai.fetelabs.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WKHTML_PKG="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-2/wkhtmltox-0.12.6-2.macos-cocoa.pkg"
STAMP="$(date +%Y%m%d-%H%M)"
BACKUP="$HOME/odoo-backup-$STAMP"

ASSUME_YES=0
REMOVE_ODOO=1
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --keep-odoo) REMOVE_ODOO=0 ;;
    --source) SOURCE="$(cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is for macOS. On Linux use install-linux.sh." >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as yourself, not with sudo. It asks for your password when it needs it." >&2
  exit 1
fi

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ask()  {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "    $* [y/N] " reply </dev/tty || true
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
backup_dir() { mkdir -p "$BACKUP"; }

brew_env() {
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# Postgres from Homebrew, once it is installed. Every psql call goes through
# this so it reaches the server Homebrew runs, whatever else is on the PATH.
pgbin() { echo "$(brew --prefix postgresql@16)/bin"; }
pg() { "$(pgbin)/psql" -X -q -At -d postgres "$@"; }

# ---------------------------------------------------------------- old Odoo

remove_odoo() {
  say "Looking for an old Odoo"

  # 1. Anything running. (macOS pgrep: -l prints the command, -f matches it.)
  local procs
  procs="$(pgrep -lf 'odoo-bin|openerp-server' | grep -v "$ROOT/" || true)"
  if [ -n "$procs" ]; then
    note "Running now:"; printf '%s\n' "$procs" | sed 's/^/      /'
    if ask "Stop these?"; then
      printf '%s\n' "$procs" | awk '{print $1}' | xargs kill 2>/dev/null || true
      sleep 3
    fi
  else
    note "No Odoo is running."
  fi

  # 2. Login items that start it.
  local plist
  for plist in "$HOME"/Library/LaunchAgents/*odoo*.plist /Library/LaunchAgents/*odoo*.plist /Library/LaunchDaemons/*odoo*.plist; do
    [ -f "$plist" ] || continue
    if ask "Stop and delete the start-up item $plist?"; then
      backup_dir; cp "$plist" "$BACKUP/"
      case "$plist" in
        "$HOME"/*) launchctl unload "$plist" 2>/dev/null || true; rm -f "$plist" ;;
        *) sudo launchctl unload "$plist" 2>/dev/null || true; sudo rm -f "$plist" ;;
      esac
    fi
  done

  # 3. Databases, in any Postgres this Mac is running.
  local psql db dbs=""
  psql="$(command -v psql || true)"
  if [ -n "$psql" ] && "$psql" -X -At -d postgres -c 'select 1' >/dev/null 2>&1; then
    for db in $("$psql" -X -At -d postgres -c "select datname from pg_database where not datistemplate and datname <> 'postgres' and pg_get_userbyid(datdba) <> 'fetelabs'"); do
      if [ "$("$psql" -X -At -d "$db" -c "select 1 from pg_class where relname = 'ir_module_module' limit 1" 2>/dev/null)" = "1" ]; then
        dbs="$dbs $db"
      fi
    done
    if [ -n "$dbs" ]; then
      note "Odoo databases:$dbs"
      backup_dir
      for db in $dbs; do
        note "Backing up $db to $BACKUP/$db.dump"
        "$(dirname "$psql")/pg_dump" -Fc -f "$BACKUP/$db.dump" "$db"
      done
      if ask "Delete these databases now that they are backed up?"; then
        for db in $dbs; do "$(dirname "$psql")/dropdb" --if-exists "$db"; done
      fi
    else
      note "No Odoo databases found."
    fi
  else
    note "No Postgres running that this account can read; databases were not checked."
  fi

  # 4. Uploaded files and settings.
  local f
  for f in "$HOME/Library/Application Support/Odoo" "$HOME/.local/share/Odoo"; do
    if [ -d "$f" ]; then
      backup_dir
      note "Backing up $f"
      tar -czf "$BACKUP/$(basename "$f")-files-$RANDOM.tar.gz" -C "$(dirname "$f")" "$(basename "$f")"
      if ask "Delete $f?"; then rm -rf "$f"; fi
    fi
  done
  for f in "$HOME/.odoorc" "$HOME/.openerp_serverrc"; do
    if [ -e "$f" ]; then
      backup_dir; cp "$f" "$BACKUP/"
      if ask "Delete $f?"; then rm -f "$f"; fi
    fi
  done

  # 5. Source folders.
  local bin dir
  while IFS= read -r bin; do
    dir="$(dirname "$bin")"
    case "$dir" in "$ROOT"*) continue ;; esac
    if [ -n "$SOURCE" ]; then case "$dir" in "$SOURCE"*) continue ;; esac; fi
    note "Odoo source folder: $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"
    if ask "Delete $dir?"; then rm -rf "$dir"; fi
  done < <(find "$HOME" -maxdepth 5 -name odoo-bin -type f \
             -not -path "$HOME/Library/*" -not -path "$HOME/.Trash/*" 2>/dev/null)

  if [ -d "$BACKUP" ]; then note "Backups are in $BACKUP"; fi
}

# ---------------------------------------------------------------- FeteLABS

install_tools() {
  say "Installing what FeteLABS needs"
  if ! xcode-select -p >/dev/null 2>&1; then
    note "Installing Apple's command line tools. A window opens: click Install,"
    note "wait for it to finish, then run this installer again."
    xcode-select --install || true
    exit 0
  fi

  brew_env
  if ! command -v brew >/dev/null 2>&1; then
    note "Installing Homebrew (it explains what it does and asks for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
    brew_env
  fi
  command -v brew >/dev/null 2>&1 || { echo "Homebrew did not install." >&2; exit 1; }

  brew install --quiet git python@3.12 postgresql@16 libpq openssl@3 pkg-config libmagic jpeg-turbo
  brew services start postgresql@16 >/dev/null

  # PDFs (invoices, receipts, tickets). The build Odoo recommends is an
  # Intel program, so an Apple Silicon Mac runs it through Rosetta.
  if [ ! -x /usr/local/bin/wkhtmltopdf ]; then
    if [ "$(uname -m)" = arm64 ] && ! /usr/bin/pgrep -q oahd; then
      note "Installing Rosetta, which the PDF tool needs on Apple Silicon"
      sudo softwareupdate --install-rosetta --agree-to-license
    fi
    local pkg="/tmp/wkhtmltox-$STAMP.pkg"
    curl -fsSL -o "$pkg" "$WKHTML_PKG"
    note "Installing the PDF tool (asks for your password)"
    sudo installer -pkg "$pkg" -target / >/dev/null
    rm -f "$pkg"
  fi
}

install_program() {
  say "Getting FeteLABS"
  mkdir -p "$ROOT" "$DATA"
  if [ -n "$SOURCE" ]; then
    rm -rf "$SRC"; cp -R "$SOURCE" "$SRC"
  elif [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC" reset --hard FETCH_HEAD
  else
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
  fi
  [ -f "$SRC/addons/fetelabs_branding/__manifest__.py" ] \
    || { echo "$SRC is not FeteLABS (no fetelabs_branding addon)." >&2; exit 1; }

  say "Installing its Python packages (a few minutes)"
  local py
  py="$(brew --prefix python@3.12)/bin/python3.12"
  [ -x "$VENV/bin/python" ] || "$py" -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip wheel

  # psycopg2 is built here and needs Postgres's and OpenSSL's headers.
  # python-ldap is left out: it only signs people in against an LDAP
  # directory, and its build on macOS needs headers Apple does not ship.
  export PATH="$(pgbin):$PATH"
  export LDFLAGS="-L$(brew --prefix openssl@3)/lib -L$(brew --prefix libpq)/lib"
  export CPPFLAGS="-I$(brew --prefix openssl@3)/include -I$(brew --prefix libpq)/include"
  grep -v -i '^python-ldap' "$SRC/requirements.txt" > "$ROOT/requirements-mac.txt"
  "$VENV/bin/pip" install -q -r "$ROOT/requirements-mac.txt" phonenumbers rl-renderPM
}

configure() {
  say "Setting up the database account and the login item"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do pg -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  if [ "$(pg -c "select 1 from pg_roles where rolname = 'fetelabs'")" != "1" ]; then
    "$(pgbin)/createuser" --createdb fetelabs
  fi

  if [ ! -f "$CONF" ]; then
    local master
    master="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    cat > "$CONF" <<EOF
[options]
; The password the database manager asks for when you create, copy or
; delete a company database. Keep it somewhere safe.
admin_passwd = $master
db_host = False
db_user = fetelabs
addons_path = $SRC/addons,$SRC/odoo/addons
data_dir = $DATA
bin_path = /usr/local/bin
http_interface = 127.0.0.1
http_port = $PORT
list_db = True
without_demo = True
EOF
    chmod 600 "$CONF"
    printf 'FeteLABS master password: %s\n(also in %s)\n' "$master" "$CONF" \
      > "$HOME/Desktop/FeteLABS-master-password.txt"
    chmod 600 "$HOME/Desktop/FeteLABS-master-password.txt"
  fi

  mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV/bin/python</string>
    <string>$SRC/odoo-bin</string>
    <string>-c</string>
    <string>$CONF</string>
  </array>
  <key>WorkingDirectory</key><string>$SRC</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(pgbin):/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$ROOT/logs/fetelabs.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/fetelabs.log</string>
</dict>
</plist>
EOF

  # A FeteLABS app in ~/Applications that opens it, with the Fete Labs icon.
  local app="$HOME/Applications/FeteLABS.app"
  local set="$ROOT/FeteLABS.iconset"
  local png="$SRC/fetelabs/brand/fetelabs-512.png"
  rm -rf "$app" "$set"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$set"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$png" --out "$set/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); [ "$d" -le 512 ] && sips -z "$d" "$d" "$png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$app/Contents/Resources/FeteLABS.icns"
  rm -rf "$set"
  cat > "$app/Contents/MacOS/FeteLABS" <<EOF
#!/bin/bash
open "http://localhost:$PORT"
EOF
  chmod +x "$app/Contents/MacOS/FeteLABS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FeteLABS</string>
  <key>CFBundleDisplayName</key><string>FeteLABS</string>
  <key>CFBundleIdentifier</key><string>ai.fetelabs.launcher</string>
  <key>CFBundleExecutable</key><string>FeteLABS</string>
  <key>CFBundleIconFile</key><string>FeteLABS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>19.0</string>
</dict>
</plist>
EOF
  touch "$app"
}

start() {
  say "Starting FeteLABS"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  local i ok=0
  for i in $(seq 1 90); do
    if curl -fs -o /dev/null "http://localhost:$PORT/web/database/selector"; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "FeteLABS did not answer. The last lines of its log:" >&2
    tail -n 30 "$ROOT/logs/fetelabs.log" >&2 || true
    exit 1
  fi
}

if [ "$REMOVE_ODOO" -eq 1 ]; then remove_odoo; fi
install_tools
install_program
configure
start

say "FeteLABS is running at http://localhost:$PORT"
note "Open it with FeteLABS in your Applications folder (~/Applications), or that address."
note "First visit: create your company database. It asks for the master"
note "password, which is in FeteLABS-master-password.txt on your Desktop."
note "Pick your island as the country, so it sets up the right taxes."
open "http://localhost:$PORT/web/database/manager"
