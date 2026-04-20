#!/usr/bin/env bash
set -euo pipefail

# first-run.sh
# Interactive installer/updater for fresh Linux systems (Raspberry Pi OS aware)

DEFAULT_LOG_FILE="/var/log/first-run.log"
# LOG_FILE may be set to DEFAULT_LOG_FILE, or a per-user fallback (e.g. $USER_HOME/first-run.log)
# The script uses defensive defaults so logging works even when called under sudo or before
# ensure_dirs() has been run.
# Determine the invoking user (when run under sudo, SUDO_USER is the original user)
INVOKER_USER="${SUDO_USER:-}"

# Defaults
DRY_RUN=0
ASSUME_YES=0
FORCE=0

function init_user_paths() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    INVOKER_USER="${SUDO_USER}"
  else
    INVOKER_USER="$(whoami)"
  fi

  USER_HOME="$(getent passwd "${INVOKER_USER}" | cut -d: -f6 2>/dev/null || true)"
  if [[ -z "${USER_HOME}" ]]; then
    USER_HOME="${HOME:-/home/${INVOKER_USER}}"
  fi

  WORK_DIR="${USER_HOME}/first-run"
  MARKER_FILE="${USER_HOME}/.first-run.done"
  : "${LOG_FILE:=${DEFAULT_LOG_FILE}}"
}

function log() {
  local msg="$1"
  local _logfile
  _logfile="${LOG_FILE:-${DEFAULT_LOG_FILE}}"
  mkdir -p "$(dirname "${_logfile}")" 2>/dev/null || true
  echo "$(date --iso-8601=seconds) - ${msg}" | tee -a "${_logfile}"
}

function die() {
  echo "$1" >&2
  log "ERROR: $1"
  exit ${2:-1}
}

function usage() {
  cat <<EOF
Usage: $0 [init|update|status|help] [--dry-run] [--yes] [--force]

Modes:
  init     Prepare the system (run once).
  update   Apply updates / patches (safe to run multiple times).
  status   Show marker and basic system info.
  help     Show this help message.

Flags:
  --dry-run  Show what would be done without making changes.
  --yes      Non-interactive; assume yes to prompts.
  --force    Re-run init even if the marker file already exists.
EOF
}

function ensure_root() {
  if [[ $(id -u) -ne 0 ]]; then
    die "This script must be run as root. Use sudo $0"
  fi
}

function ensure_dirs() {
  init_user_paths
  mkdir -p "${WORK_DIR}"
  if [[ -w "$(dirname "${DEFAULT_LOG_FILE}")" ]]; then
    LOG_FILE="${DEFAULT_LOG_FILE}"
  else
    LOG_FILE="${USER_HOME}/first-run.log"
  fi
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}" || true
  if [[ -n "${INVOKER_USER}" ]]; then
    chown -R "${INVOKER_USER}:" "${WORK_DIR}" 2>/dev/null || true
    chown "${INVOKER_USER}:" "${LOG_FILE}" 2>/dev/null || true
  fi
}


function detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  else
    PKG_MANAGER="unknown"
  fi
  log "Detected package manager: ${PKG_MANAGER}"
}
 

function apt_update_upgrade_clean() {
  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "[dry-run] apt-get update && apt-get upgrade -y && apt-get autoremove -y && apt-get clean"
    else
      log "Running apt-get update && apt-get upgrade"
      apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      apt-get autoremove -y || true
      apt-get clean || true
    fi
  else
    log "Package manager ${PKG_MANAGER} - skipping apt-specific update/upgrade"
  fi
}

function install_packages_system() {
  local pkgs=(curl wget git ca-certificates nmap)
  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    pkgs+=(build-essential dnsutils)
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "[dry-run] apt-get install -y ${pkgs[*]}"
    else
      apt-get install -y "${pkgs[@]}"
    fi
  elif [[ "${PKG_MANAGER}" == "dnf" ]]; then
    pkgs+=(bind-utils)
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "[dry-run] dnf install -y ${pkgs[*]}"
    else
      dnf install -y "${pkgs[@]}"
    fi
  else
    log "No automatic package installation for ${PKG_MANAGER}. Please install: ${pkgs[*]}"
  fi
}

function install_python_runtime() {
  log "Installing system-wide Python runtime and libraries"
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] apt-get install -y python3 python3-pip python3-venv python3-dev python3-distutils python3-setuptools python3-wheel python-is-python3 python3-requests python3-serial python3-pymodbus python3-mysql.connector"
    log "[dry-run] pip3 install --upgrade pip requests pymodbus pyserial mysql-connector-python"
    return
  fi

  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    local py_pkgs=(
      python3
      python3-pip
      python3-venv
      python3-dev
      python3-distutils
      python3-setuptools
      python3-wheel
      python-is-python3
      python3-requests
      python3-serial
      python3-pymodbus
      python3-mysql.connector
    )
    if ! apt-get install -y "${py_pkgs[@]}"; then
      log "Warning: some Python packages could not be installed via apt; continuing"
    fi
  else
    log "Package manager ${PKG_MANAGER} not supported for automated Python installs"
  fi

  if command -v pip3 >/dev/null 2>&1; then
    # Detect if pip supports --break-system-packages (needed on Debian 12+ / Bookworm)
    local pip_sys_args=()
    if pip3 install --help 2>/dev/null | grep -q 'break-system-packages'; then
      pip_sys_args+=(--break-system-packages)
    fi
    if ! pip3 install --upgrade "${pip_sys_args[@]}" pip >/dev/null 2>&1; then
      log "Warning: pip upgrade failed"
    fi
    local pip_modules=(requests pymodbus pyserial mysql-connector-python)
    if ! pip3 install --upgrade "${pip_sys_args[@]}" "${pip_modules[@]}"; then
      log "Warning: pip3 install of python modules returned an error"
    fi
  else
    log "pip3 not found after installation attempts"
  fi
}

function install_nodejs_lts() {
  log "Installing Node.js LTS (latest)"
  if command -v node >/dev/null 2>&1; then
    log "node already installed: $(node --version 2>/dev/null || true)"
    return
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] install Node.js LTS (NodeSource setup + apt-get install -y nodejs)"
    return
  fi

  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    # Use NodeSource setup script for the LTS stream
    if command -v curl >/dev/null 2>&1; then
      log "Adding NodeSource Node.js LTS repository"
      log "WARNING: Executing remote NodeSource setup script via curl | bash. Verify the source at https://deb.nodesource.com/setup_lts.x before running in sensitive environments."
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || log "Warning: NodeSource setup script returned non-zero"
      apt-get install -y nodejs || log "Warning: installing nodejs via apt failed"
    else
      log "curl not available to add NodeSource repository; please install nodejs manually"
    fi
  else
    log "Package manager ${PKG_MANAGER} not supported for automated Node.js LTS install. Please install Node.js LTS manually (nvm, distro packages, or NodeSource)."
  fi
}

function install_mariadb() {
  log "Installing MariaDB server and client"
  # Configurables: usuario, contraseña, bases (coma-separadas) y SQL inicial opcional
  : "${MARIA_DB_USER:=appuser}"
  if [[ -t 0 ]]; then
    read -rp "Usuario para originar base de datos MariaDB [${MARIA_DB_USER}]: " mariadb_usr
    MARIA_DB_USER="${mariadb_usr:-$MARIA_DB_USER}"
  fi
  : "${MARIA_DB_PASS:=}"
  if [[ -t 0 && -z "${MARIA_DB_PASS}" ]]; then
    read -rsp "Contrasena para base de datos MariaDB para el usuario ${MARIA_DB_USER} (en blanco para dejar vacio): " mariadb_pwd
    echo
    if [[ -n "${mariadb_pwd}" ]]; then MARIA_DB_PASS="${mariadb_pwd}"; fi
  fi
  : "${MARIA_DB_NAMES:=appdb}"
  if [[ -t 0 && "${MARIA_DB_NAMES}" == "appdb" ]]; then
    read -rp "Nombre de la base de datos MariaDB (separado por comas) [${MARIA_DB_NAMES}]: " mariadb_dbs
    MARIA_DB_NAMES="${mariadb_dbs:-$MARIA_DB_NAMES}"
  fi
  : "${MARIA_DB_INIT_SQL:=}"

  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] apt-get install -y mariadb-server mariadb-client libmariadb-dev"
    log "[dry-run] systemctl enable --now mariadb"
    log "[dry-run] will create DB(s): ${MARIA_DB_NAMES}, user: ${MARIA_DB_USER} (password hidden)"
    if [[ -n "${MARIA_DB_INIT_SQL}" ]]; then
      log "[dry-run] would execute additional init SQL from MARIA_DB_INIT_SQL"
    else
      log "[dry-run] would create a default sample table in each DB"
    fi
    return
  fi

  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    local db_pkgs=(mariadb-server mariadb-client libmariadb-dev)
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${db_pkgs[@]}"; then
      log "Warning: MariaDB packages could not be fully installed"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable mariadb.service >/dev/null 2>&1 || true
      systemctl start mariadb.service >/dev/null 2>&1 || true
    fi

    # Wait for mysql socket to be ready
    local wait=0
    local max_wait=30
    while ! mysql -e 'SELECT 1' >/dev/null 2>&1; do
      if (( wait >= max_wait )); then
        log "MariaDB did not become available after ${max_wait}s"
        return 1
      fi
      sleep 1
      wait=$((wait+1))
    done

    # Build SQL: create DBs, create user, grant privileges
    local sql=""
    # Escape single quotes in user and password to prevent SQL injection
    local esc_user esc_pass
    esc_user="$(printf '%s' "${MARIA_DB_USER}" | sed "s/'/\\''/g")"
    esc_pass="$(printf '%s' "${MARIA_DB_PASS}" | sed "s/'/\\''/g")"

    sql+="CREATE USER IF NOT EXISTS '${esc_user}'@'localhost' IDENTIFIED BY '${esc_pass}';\n"
    IFS=',' read -r -a _dbs <<< "${MARIA_DB_NAMES}"
    local db safe_db
    for db in "${_dbs[@]}"; do
      db="$(echo "${db}" | xargs)"
      if [[ -z "${db}" ]]; then
        continue
      fi
      # Strip characters not safe for backtick-quoted identifiers (allow alnum and underscore only)
      safe_db="$(printf '%s' "${db}" | tr -cd '[:alnum:]_')"
      if [[ -z "${safe_db}" ]]; then
        log "Warning: DB name '${db}' stripped to empty after sanitization; skipping"
        continue
      fi
      sql+="CREATE DATABASE IF NOT EXISTS \`${safe_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n"
      sql+="GRANT ALL PRIVILEGES ON \`${safe_db}\`.* TO '${esc_user}'@'localhost';\n"
    done
    sql+="FLUSH PRIVILEGES;\n"

    if [[ -n "${MARIA_DB_INIT_SQL}" ]]; then
      sql+="-- custom init SQL follows\n${MARIA_DB_INIT_SQL}\n"
    else
      # Create a sample table in each DB to ensure schema exists
      for db in "${_dbs[@]}"; do
        db="$(echo "${db}" | xargs)"
        if [[ -z "${db}" ]]; then
          continue
        fi
        safe_db="$(printf '%s' "${db}" | tr -cd '[:alnum:]_')"
        if [[ -z "${safe_db}" ]]; then
          continue
        fi
        sql+="USE \`${safe_db}\`; CREATE TABLE IF NOT EXISTS sample_table (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(255) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);\n"
      done
    fi

    # Execute as root using mysql client
    if ! mysql -e "${sql}" >/dev/null 2>&1; then
      log "Warning: executing MariaDB initialization SQL returned non-zero (attempting to run without redirect for diagnostics)"
      mysql -e "${sql}" || log "MariaDB init failed"
    else
      log "MariaDB databases, user and initial tables created/verified"
    fi

  else
    log "Package manager ${PKG_MANAGER} not supported for automated MariaDB installs"
  fi
}

function install_cloudflared() {
  log "Installing cloudflared"
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared already installed"
    return
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] install cloudflared (download latest release from GitHub)"
    return
  fi

  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|amd64) PATTERN="(amd64|x86_64|linux-amd64|linux-x86)";;
    aarch64|arm64) PATTERN="(arm64|aarch64|linux-arm64)";;
    armv7l|armv6l) PATTERN="(armv7|armv6|armhf|linux-armv7)";;
    i386|i686) PATTERN="(386|i386|i686)";;
    *) PATTERN="linux";;
  esac

  log "Detected arch ${ARCH}, searching cloudflared release assets matching: ${PATTERN}"
  JSON=$(curl -sS "https://api.github.com/repos/cloudflare/cloudflared/releases/latest") || true

  # Prefer .deb for Debian-based systems
  if command -v apt-get >/dev/null 2>&1; then
    URL=$(echo "${JSON}" | grep -E 'browser_download_url' | grep -Ei "${PATTERN}.*\\.deb" | head -n1 | sed -E 's/.*"([^\"]+)".*/\1/')
    if [[ -n "${URL}" ]]; then
      TMP_DEB="/tmp/cloudflared.deb"
      log "Downloading ${URL}"
      curl -L -o "${TMP_DEB}" "${URL}" || die "Failed to download cloudflared .deb"
      dpkg -i "${TMP_DEB}" || apt-get install -f -y || log "dpkg install failed, attempted to fix dependencies"
      rm -f "${TMP_DEB}"
      if command -v cloudflared >/dev/null 2>&1; then
        log "cloudflared installed via .deb"
        return
      else
        log "cloudflared binary not found after .deb install"
      fi
    fi
  fi

  # Fallback: find a binary/tarball matching arch
  URL=$(echo "${JSON}" | grep -E 'browser_download_url' | grep -Ei "${PATTERN}.*(tar.gz|tgz|zip|linux)" | head -n1 | sed -E 's/.*"([^\"]+)".*/\1/')
  if [[ -z "${URL}" ]]; then
    log "Could not find a cloudflared release asset matching '${PATTERN}'. Please install manually."
    return
  fi

  TMP_ARCHIVE="/tmp/cloudflared_release"
  mkdir -p "${TMP_ARCHIVE}"
  TMP_FILE="${TMP_ARCHIVE}/cloudflared_asset"
  log "Downloading ${URL}"
  curl -L -o "${TMP_FILE}" "${URL}" || die "Failed to download cloudflared from ${URL}"

  # Try extracting or moving binary
  if file "${TMP_FILE}" | grep -qiE "gzip|tar"; then
    tar -xzf "${TMP_FILE}" -C "${TMP_ARCHIVE}" || die "Failed to extract cloudflared archive"
    BIN_PATH=$(find "${TMP_ARCHIVE}" -type f -name cloudflared -perm /111 | head -n1 || true)
  elif file "${TMP_FILE}" | grep -qi "Zip archive"; then
    unzip -qq "${TMP_FILE}" -d "${TMP_ARCHIVE}" || die "Failed to unzip cloudflared archive"
    BIN_PATH=$(find "${TMP_ARCHIVE}" -type f -name cloudflared -perm /111 | head -n1 || true)
  else
    # If it's already a binary
    BIN_PATH="${TMP_FILE}"
  fi

  if [[ -z "${BIN_PATH}" ]]; then
    die "cloudflared binary not found inside the downloaded asset"
  fi

  mv "${BIN_PATH}" /usr/local/bin/cloudflared || die "Failed to move cloudflared binary to /usr/local/bin"
  chmod +x /usr/local/bin/cloudflared || true
  rm -rf "${TMP_ARCHIVE}"
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared installed to /usr/local/bin/cloudflared"
  else
    log "Installation finished but cloudflared not found in PATH"
  fi
}

function install_ttyd() {
  log "Installing ttyd"
  if command -v ttyd >/dev/null 2>&1; then
    log "ttyd already installed"
    return
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] install ttyd (download latest release from GitHub)"
    return
  fi

  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|amd64) PATTERN="x86_64|amd64|linux.*x86";;
    aarch64|arm64) PATTERN="aarch64|arm64|linux.*aarch64|linux-arm64";;
    armv7l|armv6l) PATTERN="armv7|armv6|armhf|linux.*arm";;
    *) PATTERN="linux";;
  esac

  log "Detected arch ${ARCH}, searching release assets for pattern: ${PATTERN}"

  # Query GitHub API for latest release and pick an asset matching our arch
  JSON=$(curl -sS "https://api.github.com/repos/tsl0922/ttyd/releases/latest") || true
  URL=$(echo "${JSON}" | grep -E 'browser_download_url' | grep -Ei "${PATTERN}" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')

  if [[ -z "${URL}" ]]; then
    log "Could not find a ttyd release asset matching '${PATTERN}'. Falling back to apt install if available."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y ttyd || log "apt-get install ttyd failed"
    else
      die "ttyd installation not possible automatically for this system. Please install manually."
    fi
    return
  fi

  TMP_ARCHIVE="/tmp/ttyd_release.tar.gz"
  TMP_DIR="/tmp/ttyd_extract"
  mkdir -p "${TMP_DIR}"
  log "Downloading ${URL}"
  # Use a temp file which may be an archive or a straight binary
  TMP_FILE="/tmp/ttyd_asset_$$"
  curl -L -o "${TMP_FILE}" "${URL}" || die "Failed to download ttyd from ${URL}"

  # Try extracting if it's a tar.gz/tar/xz/zip, otherwise treat as a raw binary
  if file "${TMP_FILE}" | grep -qiE "gzip|tar|XZ|bzip2|Zip archive"; then
    tar -xzf "${TMP_FILE}" -C "${TMP_DIR}" || {
      # Try unzip as fallback for zip
      if file "${TMP_FILE}" | grep -qi "Zip archive"; then
        unzip -qq "${TMP_FILE}" -d "${TMP_DIR}" || die "Failed to unzip ttyd archive"
      else
        die "Failed to extract ttyd archive"
      fi
    }

    # Find binary inside archive
    BIN_PATH=$(find "${TMP_DIR}" -type f -name ttyd -perm /111 | head -n1 || true)
  else
    # Not an archive; treat the downloaded file as the binary
    BIN_PATH="${TMP_FILE}"
    chmod +x "${BIN_PATH}" || true
  fi
  if [[ -z "${BIN_PATH}" ]]; then
    BIN_PATH=$(find "${TMP_DIR}" -type f -iname '*ttyd*' | head -n1 || true)
  fi
  if [[ -z "${BIN_PATH}" ]]; then
    die "ttyd binary not found inside the downloaded archive"
  fi

  mv "${BIN_PATH}" /usr/local/bin/ttyd || die "Failed to move ttyd binary to /usr/local/bin"
  chmod +x /usr/local/bin/ttyd || true
  rm -rf "${TMP_DIR}" || true
  rm -f "${TMP_FILE}" || true
  log "ttyd installed to /usr/local/bin/ttyd"
}

function install_filebrowser() {
  log "Installing filebrowser"
  if command -v filebrowser >/dev/null 2>&1; then
    log "filebrowser already installed"
    return
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] install filebrowser (download latest release from GitHub)"
    return
  fi

  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|amd64) PATTERN="linux.*amd64|linux.*x86_64|amd64|x86_64";;
    aarch64|arm64) PATTERN="linux.*arm64|linux.*aarch64|arm64|aarch64";;
    armv7l|armv6l) PATTERN="linux.*armv7|linux.*armhf|armv7|armhf";;
    *) PATTERN="linux";;
  esac

  log "Detected arch ${ARCH}, searching filebrowser release assets matching: ${PATTERN}"
  JSON=$(curl -sS "https://api.github.com/repos/filebrowser/filebrowser/releases/latest") || true
  URL=$(echo "${JSON}" | grep -E 'browser_download_url' | grep -Ei "${PATTERN}" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')

  if [[ -z "${URL}" ]]; then
    log "Could not find filebrowser release asset matching '${PATTERN}'. Falling back to apt if available or asking for manual install."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y filebrowser || log "apt-get install filebrowser failed"
    else
      die "filebrowser installation not possible automatically for this system. Please install manually."
    fi
    return
  fi

  TMP_ARCHIVE="/tmp/filebrowser_release.tar.gz"
  TMP_DIR="/tmp/filebrowser_extract"
  mkdir -p "${TMP_DIR}"
  log "Downloading ${URL}"
  curl -L -o "${TMP_ARCHIVE}" "${URL}" || die "Failed to download filebrowser from ${URL}"
  tar -xzf "${TMP_ARCHIVE}" -C "${TMP_DIR}" || die "Failed to extract filebrowser archive"

  # Find binary inside archive
  BIN_PATH=$(find "${TMP_DIR}" -type f -name filebrowser -perm /111 | head -n1 || true)
  if [[ -z "${BIN_PATH}" ]]; then
    BIN_PATH=$(find "${TMP_DIR}" -type f -iname '*filebrowser*' | head -n1 || true)
  fi
  if [[ -z "${BIN_PATH}" ]]; then
    die "filebrowser binary not found inside the downloaded archive"
  fi

  mv "${BIN_PATH}" /usr/local/bin/filebrowser || die "Failed to move filebrowser binary to /usr/local/bin"
  chmod +x /usr/local/bin/filebrowser || true
  rm -rf "${TMP_DIR}" "${TMP_ARCHIVE}"
  # Verificar que el binario sea ejecutable y funcional. Si no, intentar fallback via apt
  if command -v /usr/local/bin/filebrowser >/dev/null 2>&1; then
    if ! /usr/local/bin/filebrowser --version >/dev/null 2>&1 && ! /usr/local/bin/filebrowser version >/dev/null 2>&1; then
      log "filebrowser binary appears to be non-functional; attempting apt fallback"
      if [[ "${PKG_MANAGER}" == "apt" ]]; then
        apt-get update -y || true
        if apt-get install -y filebrowser; then
          log "filebrowser installed via apt as fallback"
        else
          log "apt fallback install failed; filebrowser may be unusable"
        fi
      else
        log "No apt available for fallback; filebrowser binary may be unusable"
      fi
    else
      log "filebrowser installed to /usr/local/bin/filebrowser"
    fi
  else
    log "filebrowser binary not found in PATH after installation"
  fi
}

function install_wpa_supplicant() {
  log "Ensuring wpa_supplicant (or compatible Wi‑Fi stack) is available"

  # Respect dry-run
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log "[dry-run] check/install wpa_supplicant (skip if iwd or NetworkManager present)"
    return
  fi

  # If iwd present and active, prefer it
  if command -v iwctl >/dev/null 2>&1 && systemctl is-active --quiet iwd.service; then
    log "iwd present and active; skipping wpa_supplicant install"
    return
  fi

  # If NetworkManager present and appears to manage wifi, skip installing wpa_supplicant
  if command -v nmcli >/dev/null 2>&1; then
    # If any wifi device exists, assume NetworkManager will handle it
    if nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {exit 0} END {exit 1}'; then
      log "NetworkManager present; assuming it manages Wi‑Fi (skip wpa_supplicant install)"
      return
    fi
  fi

  # If wpa_supplicant utilities present, nothing to do
  if command -v wpa_passphrase >/dev/null 2>&1 || command -v wpa_supplicant >/dev/null 2>&1; then
    log "wpa_supplicant utilities present; no install required"
    return
  fi

  # Otherwise attempt install (only for apt)
  if [[ "${PKG_MANAGER}" == "apt" ]]; then
    log "Attempting to install wpa_supplicant via apt"
    apt-get update -y || true
    apt-get install -y wpasupplicant || log "Warning: apt install wpasupplicant failed"
  else
    log "Package manager ${PKG_MANAGER:-unknown} - cannot auto-install wpa_supplicant. Please install if Wi‑Fi is required."
  fi
}

function check_requirements() {
  log "Checking system requirements"
  local missing=()

  # Root
  if [[ $(id -u) -ne 0 ]]; then
    missing+=("root (run with sudo)")
  fi

  # Basic required commands
  local cmds=(curl tar wget uname sed awk)
  for c in "${cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done

  # network connectivity (quick GitHub API check)
  if ! curl -fsS --max-time 5 https://api.github.com >/dev/null 2>&1; then
    missing+=("network (cannot reach api.github.com)")
  fi

  # disk space for /tmp or WORK_DIR
  local check_dir="/tmp"
  if [[ -n "${WORK_DIR:-}" ]]; then check_dir="${WORK_DIR}"; fi
  local avail_kb
  avail_kb=$(df --output=avail "$check_dir" 2>/dev/null | tail -n1 || echo 0)
  if [[ -z "$avail_kb" ]]; then avail_kb=0; fi
  if (( avail_kb < 200*1024 )); then
    missing+=("low disk space in ${check_dir} (<200MB)")
  fi

  # Check for apt/dpkg locks and attempt auto-recovery when possible
  if command -v apt-get >/dev/null 2>&1; then
    if ! wait_for_apt_lock; then
      missing+=("apt/dpkg lock detected or recovery failed (another package process may be running)")
    fi
  fi

  if (( ${#missing[@]} > 0 )); then
    log "Requirements check FAILED. Missing or problematic items:"
    for it in "${missing[@]}"; do
      log " - ${it}"
    done
    log "Please fix the above and re-run the script."
    return 1
  fi

  log "Requirements check passed"
  return 0
}

function wait_for_apt_lock() {
  # Wait for common apt/dpkg locks to be released, with retries and optional cleanup
  local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/cache/apt/archives/lock")
  local max_wait=60  # seconds total
  local waited=0
  local interval=3

  while (( waited < max_wait )); do
    local any_lock=0
    for l in "${locks[@]}"; do
      if [[ -e "$l" ]]; then
        # If lsof or fuser indicate a process holds it, treat as active
        if command -v lsof >/dev/null 2>&1; then
          if lsof "$l" >/dev/null 2>&1; then
            any_lock=1
          fi
        elif command -v fuser >/dev/null 2>&1; then
          if fuser "$l" >/dev/null 2>&1; then
            any_lock=1
          fi
        else
          any_lock=1
        fi
      fi
    done
    if (( any_lock == 0 )); then
      return 0
    fi
    log "apt/dpkg lock(s) present; waiting ${interval}s (waited ${waited}s)"
    sleep ${interval}
    waited=$((waited+interval))
  done

  # After waiting, if locks still present, offer or attempt cleanup when --yes is passed
  log "apt/dpkg locks still present after ${max_wait}s"
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] would attempt to recover from apt locks (no changes in dry-run)"
    return 1
  fi

  if [[ ${ASSUME_YES} -eq 0 ]]; then
    echo "apt/dpkg locks persist. Attempt automatic recovery? This may remove stale lock files and run 'dpkg --configure -a'. [y/N]"
    read -r ans
    if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
      log "User chose not to attempt apt lock recovery"
      return 1
    fi
  fi

  log "Attempting apt lock cleanup"
  # Try to run dpkg --configure -a which may clear locks
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --configure -a || log "dpkg --configure -a returned non-zero"
  fi
  # Remove common lock files if still present (best-effort)
  local removed=0
  for l in "${locks[@]}"; do
    if [[ -e "$l" ]]; then
      rm -f "$l" && removed=1 && log "Removed lock $l" || log "Failed to remove lock $l"
    fi
  done

  if (( removed == 1 )); then
    log "Attempted lock removal; continuing"
    return 0
  fi

  log "Could not clear apt/dpkg locks automatically"
  return 1
}

function restart_if_active() {
  local svc="$1"
  if systemctl list-units --type=service | grep -q "${svc}.service"; then
    log "Restarting ${svc}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
      systemctl restart "${svc}" || log "Failed to restart ${svc}"
    else
      log "[dry-run] systemctl restart ${svc}"
    fi
  fi
}

function do_init() {
  ensure_root

  # Ensure user-related paths (MARKER_FILE, WORK_DIR, LOG_FILE) are initialized
  init_user_paths
  log "Starting init"
  if [[ -f "${MARKER_FILE}" ]]; then
    if [[ ${FORCE} -eq 1 ]]; then
      log "Marker file ${MARKER_FILE} exists but --force passed — re-running init"
      rm -f "${MARKER_FILE}"
    else
      log "Marker file ${MARKER_FILE} exists — init already completed (use --force to re-run)"
      return
    fi
  fi

  ensure_dirs
  detect_package_manager
  if ! check_requirements; then
    die "Pre-flight requirements not satisfied"
  fi

  # Confirm interactive prompts
  if [[ ${ASSUME_YES} -eq 0 ]]; then
    echo "About to run init which will update packages and install: cloudflared, ttyd, filebrowser, wpa_supplicant. Proceed? [y/N]"
    read -r ans
    if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
      log "User aborted init"
      return
    fi
  fi

  apt_update_upgrade_clean
  install_packages_system
  install_python_runtime
  install_nodejs_lts
  install_mariadb
  install_cloudflared
  # Prefer running the local ensure-* helpers (they perform config + systemd units)
  ENSURE_TTYD_SCRIPT="${WORK_DIR}/ensure-ttyd.sh"
  ENSURE_FILEBROWSER_SCRIPT="${WORK_DIR}/ensure-filebrowser.sh"

  if [[ -x "${ENSURE_TTYD_SCRIPT}" ]]; then
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "[dry-run] would run ${ENSURE_TTYD_SCRIPT}"
    else
      log "Preparing to run ${ENSURE_TTYD_SCRIPT}"
      # Ensure script is owned by the invoking user and executable
      chown "${INVOKER_USER}:" "${ENSURE_TTYD_SCRIPT}" 2>/dev/null || true
      chmod +x "${ENSURE_TTYD_SCRIPT}" 2>/dev/null || true
      log "Running ${ENSURE_TTYD_SCRIPT} (output appended to ${LOG_FILE})"
      if bash "${ENSURE_TTYD_SCRIPT}" 2>&1 | tee -a "${LOG_FILE}"; then
        log "${ENSURE_TTYD_SCRIPT} completed successfully"
      else
        log "${ENSURE_TTYD_SCRIPT} failed (see ${LOG_FILE})"
      fi
    fi
  else
    log "${ENSURE_TTYD_SCRIPT} not found or not executable; falling back to install_ttyd"
    install_ttyd
  fi

  if [[ -x "${ENSURE_FILEBROWSER_SCRIPT}" ]]; then
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "[dry-run] would run ${ENSURE_FILEBROWSER_SCRIPT}"
    else
      log "Preparing to run ${ENSURE_FILEBROWSER_SCRIPT}"
      chown "${INVOKER_USER}:" "${ENSURE_FILEBROWSER_SCRIPT}" 2>/dev/null || true
      chmod +x "${ENSURE_FILEBROWSER_SCRIPT}" 2>/dev/null || true
      log "Running ${ENSURE_FILEBROWSER_SCRIPT} (output appended to ${LOG_FILE})"
      if bash "${ENSURE_FILEBROWSER_SCRIPT}" 2>&1 | tee -a "${LOG_FILE}"; then
        log "${ENSURE_FILEBROWSER_SCRIPT} completed successfully"
      else
        log "${ENSURE_FILEBROWSER_SCRIPT} failed (see ${LOG_FILE})"
      fi
    fi
  else
    log "${ENSURE_FILEBROWSER_SCRIPT} not found or not executable; falling back to install_filebrowser"
    install_filebrowser
  fi
  install_wpa_supplicant

  # Restart services commonly used
  restart_if_active ssh
  restart_if_active cron

  if [[ ${DRY_RUN} -eq 0 ]]; then
    mkdir -p "$(dirname "${MARKER_FILE}")"
    touch "${MARKER_FILE}"
    log "Created marker ${MARKER_FILE}"
  else
    log "[dry-run] would create marker ${MARKER_FILE}"
  fi

  log "Init completed"
}

function get_github_latest_version() {
  # Usage: get_github_latest_version owner/repo
  local repo="$1"
  local tag
  tag=$(curl -sS "https://api.github.com/repos/${repo}/releases/latest" \
    | grep '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/' \
    | head -n1 || true)
  printf '%s' "${tag}"
}

function get_installed_version() {
  local cmd="$1"
  local version
  version=$("${cmd}" --version 2>/dev/null || "${cmd}" version 2>/dev/null || true)
  printf '%s' "${version}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

function check_and_update_binary() {
  local name="$1"
  local repo="$2"
  local install_fn="$3"

  if ! command -v "${name}" >/dev/null 2>&1; then
    log "${name}: not installed; skipping update"
    return
  fi

  local installed latest
  installed=$(get_installed_version "${name}")
  latest=$(get_github_latest_version "${repo}")

  if [[ -z "${latest}" ]]; then
    log "${name}: could not fetch latest version from GitHub; skipping"
    return
  fi

  if [[ "${installed}" == "${latest}" ]]; then
    log "${name}: already at latest version ${installed}"
    return
  fi

  log "${name}: installed=${installed:-unknown} latest=${latest} — updating"
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] would update ${name} to ${latest}"
    return
  fi

  # Remove binary so install function skips the early-return guard
  local bin_path
  bin_path=$(command -v "${name}")
  rm -f "${bin_path}" || true
  "${install_fn}"
}

function do_update() {
  ensure_root
  log "Starting update"
  ensure_dirs
  detect_package_manager
  if ! check_requirements; then
    die "Pre-flight requirements not satisfied"
  fi

  apt_update_upgrade_clean

  log "Checking tool versions..."
  check_and_update_binary "cloudflared" "cloudflare/cloudflared" "install_cloudflared"
  check_and_update_binary "ttyd"        "tsl0922/ttyd"           "install_ttyd"
  check_and_update_binary "filebrowser" "filebrowser/filebrowser" "install_filebrowser"

  log "Update finished"
}

function do_status() {
  init_user_paths
  echo "Marker: ${MARKER_FILE} -> $( [[ -f "${MARKER_FILE}" ]] && echo exists || echo missing )"
  echo "Package manager: ${PKG_MANAGER:-unknown}"
  echo "User: ${SUDO_USER:-$(whoami)}"
}

### Main
if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

MODE="$1"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    --force|-f) FORCE=1; shift;;
    --help|-h) usage; exit 0;;
    *) shift;;
  esac
done

case "${MODE}" in
  init) do_init;;
  update) do_update;;
  status) detect_package_manager; do_status;;
  help|--help) usage;;
  *) usage; exit 2;;
esac
