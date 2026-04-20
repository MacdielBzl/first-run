#!/usr/bin/env bash
set -euo pipefail

# ensure-filebrowser.sh
# Garantiza que filebrowser esté instalado, configurado y ejecutándose como
# servicio systemd escuchando en 127.0.0.1:${FILEBROWSER_PORT:-8080} con un usuario administrador predeterminado.

FILEBROWSER_PORT="${FILEBROWSER_PORT:-8080}"
SERVICE_NAME="filebrowser.service"
CONFIG_DIR="/etc/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_DIR="/var/lib/filebrowser"
DB_FILE="${DATA_DIR}/filebrowser.db"
LOG_PATH="/var/log/filebrowser.log"

FILEBROWSER_ROOT="${FILEBROWSER_ROOT:-/}"
FILEBROWSER_SCOPE="${FILEBROWSER_SCOPE:-/}"
FILEBROWSER_BASEURL="${FILEBROWSER_BASEURL:-/files}"
FILEBROWSER_SERVICE_USER="${FILEBROWSER_SERVICE_USER:-pi}"
FILEBROWSER_SERVICE_GROUP="${FILEBROWSER_SERVICE_GROUP:-${FILEBROWSER_SERVICE_USER}}"

# Filebrowser app users to create inside filebrowser's DB (not system users)
REQUIRED_USER="pi"
if [[ -t 0 && -z "${FILEBROWSER_USER_PASSWORD:-}" ]]; then
  read -rp "Usuario estandar de filebrowser [${REQUIRED_USER}]: " usr_inp
  REQUIRED_USER="${usr_inp:-$REQUIRED_USER}"
fi
REQUIRED_PASSWORD="${FILEBROWSER_USER_PASSWORD:-}"
if [[ -t 0 && -z "${REQUIRED_PASSWORD}" ]]; then
  read -rsp "Contrasena para ${REQUIRED_USER} (en blanco para autogenerar): " pwd_inp
  echo
  if [[ -n "${pwd_inp}" ]]; then REQUIRED_PASSWORD="${pwd_inp}"; fi
fi

# Administrative user inside filebrowser
FB_ADMIN_USER="root"
if [[ -t 0 && -z "${FILEBROWSER_ADMIN_PASSWORD:-}" ]]; then
  read -rp "Usuario admin de filebrowser [${FB_ADMIN_USER}]: " usr_adm
  FB_ADMIN_USER="${usr_adm:-$FB_ADMIN_USER}"
fi
FB_ADMIN_PASSWORD="${FILEBROWSER_ADMIN_PASSWORD:-}"
if [[ -t 0 && -z "${FB_ADMIN_PASSWORD}" ]]; then
  read -rsp "Contrasena admin para filebrowser (en blanco para autogenerar): " pwd_adm
  echo
  if [[ -n "${pwd_adm}" ]]; then FB_ADMIN_PASSWORD="${pwd_adm}"; fi
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Este script debe ejecutarse con privilegios de administrador (sudo)." >&2
  exit 1
fi

# Validate port is integer and within valid range
if ! [[ "${FILEBROWSER_PORT}" =~ ^[0-9]+$ ]]; then
  echo "Puerto inválido: ${FILEBROWSER_PORT}. Debe ser un número entero." >&2
  exit 1
fi
if (( FILEBROWSER_PORT < 1 || FILEBROWSER_PORT > 65535 )); then
  echo "Puerto fuera de rango: ${FILEBROWSER_PORT}. Debe estar entre 1 y 65535." >&2
  exit 1
fi

INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" ]]; then
  INVOKER_USER=$(logname 2>/dev/null || whoami)
fi

USER_HOME=$(getent passwd "${INVOKER_USER}" | cut -d: -f6 2>/dev/null || true)
if [[ -z "${USER_HOME}" ]]; then
  USER_HOME="/home/${INVOKER_USER}"
fi

if ! id "${FILEBROWSER_SERVICE_USER}" >/dev/null 2>&1; then
  echo "El usuario ${FILEBROWSER_SERVICE_USER} no existe en el sistema. Este script intentará crear el usuario ${FILEBROWSER_SERVICE_USER}."
  useradd -m -s /bin/bash "${FILEBROWSER_SERVICE_USER}" || {
    echo "No se pudo crear el usuario ${FILEBROWSER_SERVICE_USER}. Ejecuta manualmente y vuelve a ejecutar." >&2
    exit 1
  }
fi

if ! getent group "${FILEBROWSER_SERVICE_GROUP}" >/dev/null 2>&1; then
  echo "El grupo ${FILEBROWSER_SERVICE_GROUP} no existe en el sistema. Configura FILEBROWSER_SERVICE_GROUP con un grupo válido." >&2
  exit 1
fi

SERVICE_HOME=$(getent passwd "${FILEBROWSER_SERVICE_USER}" | cut -d: -f6 2>/dev/null || true)
if [[ -z "${SERVICE_HOME}" ]]; then
  SERVICE_HOME="/"
fi

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function filebrowser_is_healthy() {
  if filebrowser version >/dev/null 2>&1; then
    return 0
  fi
  if filebrowser --version >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

function normalize_baseurl() {
  local input="$1"
  if [[ -z "${input}" ]]; then
    echo "/files"
    return
  fi
  if [[ "${input}" != /* ]]; then
    input="/${input}"
  fi
  if [[ "${input}" != "/" && "${input}" == */ ]]; then
    input="${input%/}"
  fi
  echo "${input}"
}

FILEBROWSER_BASEURL=$(normalize_baseurl "${FILEBROWSER_BASEURL}")

# Credentials file to store generated passwords (root-only)
CREDFILE="/root/.filebrowser_credentials"

# Generate a reasonably strong password (alphanumeric). Length default 16.
function gen_password() {
  local len=${1:-16}
  if command_exists openssl; then
    # openssl -> base64 -> filter to alnum
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${len}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
  fi
}

# Ensure passwords meet minimum length; if not, generate new ones and save
function ensure_passwords() {
  local minlen=12
  local changed=0

  if [[ -z "${REQUIRED_PASSWORD}" || ${#REQUIRED_PASSWORD} -lt ${minlen} ]]; then
    REQUIRED_PASSWORD=$(gen_password 16)
    changed=1
  fi

  if [[ -z "${FB_ADMIN_PASSWORD}" || ${#FB_ADMIN_PASSWORD} -lt ${minlen} ]]; then
    FB_ADMIN_PASSWORD=$(gen_password 24)
    changed=1
  fi

  if [[ ${changed} -ne 0 ]]; then
    # backup existing creds if present
    if [[ -f "${CREDFILE}" ]]; then
      cp -a "${CREDFILE}" "${CREDFILE}.bak.$(date +%s)" 2>/dev/null || true
    fi
    local tmpf
    tmpf=$(mktemp)
    printf '%s\n' "# filebrowser credentials generated on $(date -u '+%Y-%m-%d %H:%M:%SZ')" >"${tmpf}"
    printf 'pi:%s\n' "${REQUIRED_PASSWORD}" >>"${tmpf}"
    printf 'root:%s\n' "${FB_ADMIN_PASSWORD}" >>"${tmpf}"
    mv "${tmpf}" "${CREDFILE}" && chmod 600 "${CREDFILE}" || true
    echo "Se generaron/actualizaron contraseñas y se guardaron en: ${CREDFILE} (perm: 600)"
  fi
}

function run_as_service_user() {
  if [[ $(id -un) == "${FILEBROWSER_SERVICE_USER}" ]]; then
    "$@"
    return
  fi

  if command_exists runuser; then
    runuser -u "${FILEBROWSER_SERVICE_USER}" -- "$@"
  elif command_exists sudo; then
    sudo -u "${FILEBROWSER_SERVICE_USER}" -- "$@"
  elif command_exists su; then
    local cmd_str=""
    printf -v cmd_str '%q ' "$@"
    su -s /bin/sh "${FILEBROWSER_SERVICE_USER}" -c "${cmd_str}"
  else
    echo "No se pudo cambiar al usuario ${FILEBROWSER_SERVICE_USER}; instala runuser, sudo o su." >&2
    return 1
  fi
}

function stop_service_if_running() {
  if systemctl list-unit-files "${SERVICE_NAME}" --no-legend 2>/dev/null | grep -q .; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      systemctl stop "${SERVICE_NAME}" || true
    fi
  fi
}

function detect_asset_pattern() {
  local arch
  arch=$(uname -m)
  case "${arch}" in
    x86_64|amd64) echo "linux-amd64";;
    aarch64|arm64) echo "linux-arm64";;
    armv7l|armhf) echo "linux-armv7";;
    armv6l) echo "linux-armv6";;
    *)
      echo "Arquitectura no soportada: ${arch}" >&2
      return 1
      ;;
  esac
}

function download_and_install_filebrowser() {
  local pattern
  pattern=$(detect_asset_pattern) || return 1

  local tmpdir
  tmpdir=$(mktemp -d)
  local json_url="https://api.github.com/repos/filebrowser/filebrowser/releases/latest"
  local asset_url
  asset_url=$(curl -fsSL "${json_url}" \
    | grep -E 'browser_download_url' \
    | grep -Ei "${pattern}.*(tar.gz|tgz|zip)" \
    | head -n1 \
    | sed -E 's/.*"([^\"]+)".*/\1/')

  if [[ -z "${asset_url}" ]]; then
    echo "No se encontró un asset de filebrowser para el patrón '${pattern}'." >&2
    rm -rf "${tmpdir}"
    return 1
  fi

  local archive="${tmpdir}/filebrowser_asset"
  if ! curl -fL "${asset_url}" -o "${archive}"; then
    echo "No se pudo descargar ${asset_url}." >&2
    rm -rf "${tmpdir}"
    return 1
  fi

  if file "${archive}" | grep -qiE 'gzip|tar'; then
    if ! tar -xzf "${archive}" -C "${tmpdir}"; then
      echo "No se pudo extraer el archivo tar de filebrowser." >&2
      rm -rf "${tmpdir}"
      return 1
    fi
  elif file "${archive}" | grep -qi 'zip'; then
    if ! unzip -qq "${archive}" -d "${tmpdir}"; then
      echo "No se pudo extraer el archivo zip de filebrowser." >&2
      rm -rf "${tmpdir}"
      return 1
    fi
  else
    chmod +x "${archive}" || true
  fi

  local bin_path
  bin_path=$(find "${tmpdir}" -type f -name filebrowser -perm /111 | head -n1 || true)
  if [[ -z "${bin_path}" ]]; then
    if [[ -x "${archive}" ]]; then
      bin_path="${archive}"
    fi
  fi

  if [[ -z "${bin_path}" ]]; then
    echo "No se pudo localizar el binario de filebrowser en el asset descargado." >&2
    rm -rf "${tmpdir}"
    return 1
  fi

  install -m 0755 "${bin_path}" /usr/local/bin/filebrowser
  rm -rf "${tmpdir}"
  return 0
}

function ensure_filebrowser_installed() {
  if command_exists filebrowser; then
    if filebrowser_is_healthy; then
      return 0
    fi
    echo "El binario actual de filebrowser parece estar corrupto. Se reinstalará."
  else
    echo "filebrowser no está instalado. Intentando instalarlo..."
  fi

  stop_service_if_running

  if download_and_install_filebrowser; then
    :
  elif command_exists apt-get; then
    echo "Descarga directa falló, intentando instalar con apt..."
    apt-get update -y
    apt-get install -y filebrowser || true
  fi

  if ! command_exists filebrowser || ! filebrowser_is_healthy; then
    echo "La instalación de filebrowser falló. Instálalo manualmente y vuelve a ejecutar este script." >&2
    exit 1
  fi

  echo "filebrowser instalado correctamente."
}

function ensure_directories() {
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "$(dirname "${LOG_PATH}")"
  touch "${LOG_PATH}" 2>/dev/null || true
  # Ensure files/dirs owned by the service user (pi) so uploads belong to pi
  chown -R "${FILEBROWSER_SERVICE_USER}:${FILEBROWSER_SERVICE_GROUP}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_PATH}" 2>/dev/null || true
}

function configure_filebrowser() {
  stop_service_if_running
  ensure_directories

  rm -f "${CONFIG_FILE}" "${DB_FILE}"

  if [[ ! -d "${FILEBROWSER_ROOT}" ]]; then
    echo "La ruta FILEBROWSER_ROOT (${FILEBROWSER_ROOT}) no existe o no es un directorio." >&2
    exit 1
  fi

  if [[ ! -d "${FILEBROWSER_SCOPE}" ]]; then
    echo "La ruta FILEBROWSER_SCOPE (${FILEBROWSER_SCOPE}) no existe o no es un directorio." >&2
    exit 1
  fi

  filebrowser config init \
    --config "${CONFIG_FILE}" \
    --database "${DB_FILE}" \
    --address 127.0.0.1 \
    --port "${FILEBROWSER_PORT}" \
    --root "${FILEBROWSER_ROOT}" \
    --scope "${FILEBROWSER_SCOPE}" \
    --baseurl "${FILEBROWSER_BASEURL}" \
    --log "${LOG_PATH}"
  # Create or update non-admin user 'pi'
  if filebrowser users ls --database "${DB_FILE}" | awk 'NR>1 {print $2}' | grep -Fxq "${REQUIRED_USER}"; then
    filebrowser users update "${REQUIRED_USER}" \
      --database "${DB_FILE}" \
      --password "${REQUIRED_PASSWORD}" \
      --perm.readonly=false \
      --scope "${FILEBROWSER_SCOPE}" || true
  else
    filebrowser users add "${REQUIRED_USER}" "${REQUIRED_PASSWORD}" \
      --database "${DB_FILE}" \
      --perm.readonly=false \
      --scope "${FILEBROWSER_SCOPE}" || true
  fi

  # Create or update admin user 'root'
  if filebrowser users ls --database "${DB_FILE}" | awk 'NR>1 {print $2}' | grep -Fxq "${FB_ADMIN_USER}"; then
    filebrowser users update "${FB_ADMIN_USER}" \
      --database "${DB_FILE}" \
      --password "${FB_ADMIN_PASSWORD}" \
      --perm.admin \
      --scope "${FILEBROWSER_SCOPE}" || true
  else
    filebrowser users add "${FB_ADMIN_USER}" "${FB_ADMIN_PASSWORD}" \
      --database "${DB_FILE}" \
      --perm.admin \
      --scope "${FILEBROWSER_SCOPE}" || true
  fi

  # Ensure files and DB owned by service user so uploads appear as that system user
  chown -R "${FILEBROWSER_SERVICE_USER}:${FILEBROWSER_SERVICE_GROUP}" "${CONFIG_DIR}" "${DATA_DIR}" || true
}

function ensure_service() {
  local service_path="/etc/systemd/system/${SERVICE_NAME}"
  local filebrowser_bin
  filebrowser_bin=$(command -v filebrowser)

  cat > "${service_path}" <<EOF
[Unit]
Description=Filebrowser Web File Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FILEBROWSER_SERVICE_USER}
Group=${FILEBROWSER_SERVICE_GROUP}
WorkingDirectory=${FILEBROWSER_ROOT}
Environment=HOME=${SERVICE_HOME}
ExecStart="${filebrowser_bin}" --config "${CONFIG_FILE}" --database "${DB_FILE}"
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${service_path}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
}

function verify_service_access() {
  local -a paths=("${FILEBROWSER_SCOPE}")
  if [[ "${FILEBROWSER_SCOPE}" == "/" ]]; then
    paths+=("/etc" "/var" "/home")
  fi

  local issues=0
  for path in "${paths[@]}"; do
    if ! run_as_service_user test -r "${path}" 2>/dev/null; then
      echo "El usuario ${FILEBROWSER_SERVICE_USER} no tiene permisos de lectura sobre ${path}." >&2
      issues=1
    fi
    if ! run_as_service_user ls -A "${path}" >/dev/null 2>&1; then
      echo "El usuario ${FILEBROWSER_SERVICE_USER} no puede listar ${path}." >&2
      issues=1
    fi
  done

  if [[ ${issues} -ne 0 ]]; then
    echo "Filebrowser no cuenta con acceso completo al alcance configurado (${FILEBROWSER_SCOPE})." >&2
    exit 1
  fi
}

ensure_filebrowser_installed
ensure_passwords
configure_filebrowser
ensure_service
verify_service_access
echo "filebrowser instalado y configurado. Usuarios internos creados: ${REQUIRED_USER} (no-admin) y ${FB_ADMIN_USER} (admin)."
echo "Escuchando en 127.0.0.1:${FILEBROWSER_PORT} (base URL ${FILEBROWSER_BASEURL})."
echo "Alcance configurado: ${FILEBROWSER_SCOPE} (usuario del servicio: ${FILEBROWSER_SERVICE_USER})."