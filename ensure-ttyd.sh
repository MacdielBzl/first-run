#!/usr/bin/env bash
set -euo pipefail

# ensure-ttyd.sh
# Garantiza que ttyd esté instalado y ejecutándose como un servicio systemd
# escuchando en el puerto 3000 con acceso de escritura habilitado.

REQUIRED_PORT="${TTYD_PORT:-3000}"
TTYD_BASE_PATH="${TTYD_BASE_PATH:-/ttyd}"
SERVICE_NAME="ttyd.service"
LOG_PATH="/var/log/ttyd.log"
AUTH_USER="${TTYD_AUTH_USER:-pi}"
if [[ -t 0 && -z "${TTYD_AUTH_USER:-}" ]]; then
  read -rp "Usuario para acceso web ttyd [${AUTH_USER}]: " ttyd_usr
  AUTH_USER="${ttyd_usr:-$AUTH_USER}"
fi
AUTH_PASSWORD="${TTYD_AUTH_PASSWORD:-}"
if [[ -t 0 && -z "${AUTH_PASSWORD}" ]]; then
  read -rsp "Contrasena para acceso web ttyd (en blanco sin clave): " ttyd_pwd
  echo
  if [[ -n "${ttyd_pwd}" ]]; then AUTH_PASSWORD="${ttyd_pwd}"; fi
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Este script debe ejecutarse con privilegios de administrador (sudo)." >&2
  exit 1
fi

function normalize_base_path() {
  local input="$1"
  if [[ -z "${input}" ]]; then
    echo "/ttyd"
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

TTYD_BASE_PATH=$(normalize_base_path "${TTYD_BASE_PATH}")

INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" ]]; then
  INVOKER_USER=$(logname 2>/dev/null || whoami)
fi

USER_HOME=$(getent passwd "${INVOKER_USER}" | cut -d: -f6 2>/dev/null || true)
if [[ -z "${USER_HOME}" ]]; then
  USER_HOME="/home/${INVOKER_USER}"
fi

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if ! command_exists ttyd; then
  echo "ttyd no está instalado. Intentando instalarlo..."
  if command_exists apt-get; then
    apt-get update -y
    apt-get install -y ttyd
  else
    echo "No se puede instalar ttyd automáticamente en este sistema. Instálalo manualmente." >&2
    exit 1
  fi
fi

TTYD_BIN=$(command -v ttyd)
if [[ -z "${TTYD_BIN}" ]]; then
  echo "No se pudo localizar el binario de ttyd después de la instalación." >&2
  exit 1
fi

if [[ -z "${AUTH_USER}" ]]; then
  AUTH_USER="pi"
fi

if [[ "${AUTH_USER}" == *":"* ]]; then
  echo "El nombre de usuario de ttyd no puede contener ':'." >&2
  exit 1
fi

if [[ "${AUTH_PASSWORD}" == *":"* ]]; then
  echo "La contraseña de ttyd no puede contener ':'." >&2
  exit 1
fi

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# Validate port is integer and within valid range
if ! [[ "${REQUIRED_PORT}" =~ ^[0-9]+$ ]]; then
  echo "Puerto inválido: ${REQUIRED_PORT}. Debe ser un número entero." >&2
  exit 1
fi
if (( REQUIRED_PORT < 1 || REQUIRED_PORT > 65535 )); then
  echo "Puerto fuera de rango: ${REQUIRED_PORT}. Debe estar entre 1 y 65535." >&2
  exit 1
fi

tmp_service=$(mktemp)
CRED_ARGS=""
if [[ -n "${AUTH_PASSWORD}" ]]; then
  CRED_ARGS="--credential ${AUTH_USER}:${AUTH_PASSWORD}"
fi

cat > "${tmp_service}" <<EOF
[Unit]
Description=ttyd Web Terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${INVOKER_USER}
WorkingDirectory=${USER_HOME}
Environment=HOME=${USER_HOME}
ExecStart=${TTYD_BIN} --writable --interface 127.0.0.1 --port ${REQUIRED_PORT} --base-path ${TTYD_BASE_PATH} ${CRED_ARGS} bash
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=multi-user.target
EOF

chmod 600 "${tmp_service}"
mv "${tmp_service}" "${SERVICE_PATH}"
touch "${LOG_PATH}" 2>/dev/null || true
chown "${INVOKER_USER}:" "${LOG_PATH}" 2>/dev/null || true

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "Servicio ${SERVICE_NAME} instalado y activado en el puerto ${REQUIRED_PORT}."
echo "Puedes verificarlo con: sudo systemctl status ${SERVICE_NAME}"