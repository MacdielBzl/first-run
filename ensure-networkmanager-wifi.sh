#!/usr/bin/env bash
set -euo pipefail

# ensure-networkmanager-wifi.sh
# Asiste con tareas comunes de Wi-Fi usando NetworkManager/nmcli:
# - listar redes visibles
# - consultar el estado actual
# - conectar, desconectar y olvidar perfiles guardados.
# Requiere NetworkManager instalado y nmcli disponible.

DRY_RUN=0
DEVICE=""
RESCAN=0
DO_LIST=0
DO_STATUS=0
DO_LIST_SAVED=0
DISCONNECT=0
CONNECT_SSID=""
CONNECT_PASSWORD=""
ASK_PASSWORD=0
HIDDEN_NETWORK=0
FORGET_ID=""
NEEDS_PRIVILEGES=0
CREATE_SSID=""
AUTOCONNECT=0

function usage() {
  cat <<'EOF'
Uso: ensure-networkmanager-wifi.sh [opciones]

Acciones informativas (pueden combinarse):
  --status               Mostrar el estado del dispositivo Wi-Fi (predeterminado)
  --list                 Listar redes visibles
  --list-saved           Listar conexiones guardadas

Acciones de gestión (una por ejecución):
  --connect SSID         Conectar al SSID indicado
    --password PASS      Contraseña a usar (omitible para redes abiertas)
    --ask-password       Solicitar contraseña de manera interactiva (oculta)
    --hidden             Indicar que la red es oculta
  --disconnect           Desconectar el dispositivo Wi-Fi
  --forget IDENTIFICADOR Eliminar una conexión guardada (usar SSID o UUID)

Opciones adicionales:
  --device DEV           Dispositivo Wi-Fi a gestionar (auto si se omite)
  --rescan               Solicitar un escaneo previo de redes
  --dry-run              Mostrar acciones sin aplicar cambios
  --help                 Mostrar esta ayuda

Ejemplos:
  sudo ./ensure-networkmanager-wifi.sh --list
  sudo ./ensure-networkmanager-wifi.sh --connect MiRed --ask-password
  sudo ./ensure-networkmanager-wifi.sh --forget MiRed
EOF
}

function log() {
  printf '[ensure-nm-wifi] %s\n' "$*"
}

function pause_for_user() {
  if [[ -t 0 ]]; then
    read -rp "Press Enter to continue..." _dummy
  fi
}

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function ensure_nmcli_available() {
  if ! command_exists nmcli; then
    echo "Se requiere 'nmcli'. ¿Está instalado NetworkManager?" >&2
    exit 1
  fi
}

function ensure_root_if_needed() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    return
  fi
  if [[ ${NEEDS_PRIVILEGES} -eq 1 && $(id -u) -ne 0 ]]; then
    echo "Esta operación requiere privilegios de administrador (sudo)." >&2
    exit 1
  fi
}

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --device)
        shift
        if [[ $# -eq 0 ]]; then
          echo "--device requiere un argumento" >&2
          exit 1
        fi
        DEVICE="$1"
        ;;
      --status)
        DO_STATUS=1
        ;;
      --list)
        DO_LIST=1
        # By default, when listing visible networks, perform a rescan to show fresh results
        RESCAN=1
        NEEDS_PRIVILEGES=1
        ;;
      --list-saved)
        DO_LIST_SAVED=1
        ;;
      --rescan)
        RESCAN=1
        NEEDS_PRIVILEGES=1
        ;;
      --connect)
        shift
        if [[ $# -eq 0 ]]; then
          echo "--connect requiere un SSID" >&2
          exit 1
        fi
        if [[ -n "${CONNECT_SSID}" || -n "${FORGET_ID}" || ${DISCONNECT} -eq 1 ]]; then
          echo "Sólo una acción de gestión es permitida por ejecución." >&2
          exit 1
        fi
        CONNECT_SSID="$1"
        NEEDS_PRIVILEGES=1
        ;;
      --create)
        shift
        if [[ $# -eq 0 ]]; then
          echo "--create requiere un SSID" >&2
          exit 1
        fi
        if [[ -n "${CONNECT_SSID}" || -n "${FORGET_ID}" || ${DISCONNECT} -eq 1 || -n "${CREATE_SSID}" ]]; then
          echo "Sólo una acción de gestión es permitida por ejecución." >&2
          exit 1
        fi
        CREATE_SSID="$1"
        NEEDS_PRIVILEGES=1
        ;;
      --password)
        shift
        if [[ $# -eq 0 ]]; then
          echo "--password requiere un valor" >&2
          exit 1
        fi
        CONNECT_PASSWORD="$1"
        ;;
      --ask-password)
        ASK_PASSWORD=1
        ;;
      --hidden)
        HIDDEN_NETWORK=1
        ;;
      --disconnect)
        if [[ -n "${CONNECT_SSID}" || -n "${FORGET_ID}" || ${DISCONNECT} -eq 1 ]]; then
          echo "Sólo una acción de gestión es permitida por ejecución." >&2
          exit 1
        fi
        DISCONNECT=1
        NEEDS_PRIVILEGES=1
        ;;
      --forget)
        shift
        if [[ $# -eq 0 ]]; then
          echo "--forget requiere un identificador" >&2
          exit 1
        fi
        if [[ -n "${CONNECT_SSID}" || -n "${FORGET_ID}" || ${DISCONNECT} -eq 1 ]]; then
          echo "Sólo una acción de gestión es permitida por ejecución." >&2
          exit 1
        fi
        FORGET_ID="$1"
        NEEDS_PRIVILEGES=1
        ;;
      --autoconnect)
        AUTOCONNECT=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Opción desconocida: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done
}

function default_actions_if_none() {
  local has_management=0
  if [[ -n "${CONNECT_SSID}" || -n "${FORGET_ID}" || ${DISCONNECT} -eq 1 ]]; then
    has_management=1
  fi
  if [[ ${DO_STATUS} -eq 0 && ${DO_LIST} -eq 0 && ${DO_LIST_SAVED} -eq 0 && ${has_management} -eq 0 ]]; then
    DO_STATUS=1
  fi
}

function detect_wifi_device() {
  if [[ -n "${DEVICE}" ]]; then
    return
  fi
  local candidate
  candidate=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "wifi" {print $1; exit}')
  if [[ -z "${candidate}" ]]; then
    echo "No se detectó un dispositivo Wi-Fi gestionado por NetworkManager." >&2
    exit 1
  fi
  DEVICE="${candidate}"
}

function maybe_prompt_password() {
  if [[ -n "${CONNECT_SSID}" && ${ASK_PASSWORD} -eq 1 && -z "${CONNECT_PASSWORD}" && ${DRY_RUN} -eq 0 ]]; then
    read -rsp "Contraseña para ${CONNECT_SSID}: " CONNECT_PASSWORD
    printf "\n"
  fi
}

function log_device_context() {
  log "Dispositivo objetivo: ${DEVICE}"
}

function run_nmcli() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] nmcli $*"
    return 0
  fi
  nmcli "$@"
}

function maybe_rescan() {
  if [[ ${RESCAN} -eq 1 ]]; then
    log "Solicitando nuevo escaneo de redes..."
    run_nmcli device wifi rescan ifname "${DEVICE}"
  fi
}

function action_status() {
  if [[ ${DO_STATUS} -eq 0 ]]; then
    return
  fi
  log "Estado actual del Wi-Fi:"
  nmcli -f DEVICE,TYPE,STATE,CONNECTION device status | awk -v dev="${DEVICE}" 'NR==1 || $1==dev {print}'
  local detail_output
  detail_output=$(nmcli device show "${DEVICE}" 2>/dev/null | grep -E 'GENERAL\.STATE|GENERAL\.CONNECTION|IP4\.ADDRESS|IP6\.ADDRESS' | sed 's/^[[:space:]]*//' ) || true
  if [[ -n "${detail_output}" ]]; then
    while IFS= read -r line; do
      printf '[detalle] %s\n' "${line}"
    done <<<"${detail_output}"
  fi
}

function action_list_networks() {
  if [[ ${DO_LIST} -eq 0 ]]; then
    return
  fi
  log "Redes visibles (SSID | Seguridad | Señal):"
  nmcli -f SSID,SECURITY,SIGNAL device wifi list ifname "${DEVICE}" | sed 's/^/  /'
  pause_for_user
}

function action_list_saved() {
  if [[ ${DO_LIST_SAVED} -eq 0 ]]; then
    return
  fi
  log "Conexiones guardadas (Nombre | UUID | Dispositivo | Tipo):"
  local out
  out=$(nmcli -f NAME,UUID,DEVICE,TYPE connection show 2>/dev/null || true)
  if [[ -z "${out//[[:space:]]/}" ]]; then
    echo "  (no saved connections)"
  else
    echo "${out}" | sed 's/^/  /'
  fi
  pause_for_user
}

function action_connect() {
  if [[ -z "${CONNECT_SSID}" ]]; then
    return
  fi
  log "Intentando conectar a '${CONNECT_SSID}'..."
  local args=(device wifi connect "${CONNECT_SSID}" ifname "${DEVICE}")
  if [[ ${HIDDEN_NETWORK} -eq 1 ]]; then
    args+=(hidden yes)
  fi
  if [[ -n "${CONNECT_PASSWORD}" ]]; then
    args+=(password "${CONNECT_PASSWORD}")
  fi
  run_nmcli "${args[@]}"
}

function action_create() {
  if [[ -z "${CREATE_SSID}" ]]; then
    return
  fi
  log "Creando conexión guardada para SSID='${CREATE_SSID}' (aunque no esté visible)"
  local args=(connection add type wifi con-name "${CREATE_SSID}" ifname "${DEVICE}" ssid "${CREATE_SSID}")
  # Set mode to infrastructure (default) and autoconnect
  args+=(wifi.mode infrastructure)
  if [[ ${AUTOCONNECT} -eq 1 ]]; then
    args+=(connection.autoconnect yes)
  else
    args+=(connection.autoconnect no)
  fi
  # If password provided, create PSK (WPA-PSK)
  if [[ -n "${CONNECT_PASSWORD}" ]]; then
    args+=(wifi-sec.key-mgmt wpa-psk)
    args+=(wifi-sec.psk "${CONNECT_PASSWORD}")
  fi

  if [[ ${HIDDEN_NETWORK} -eq 1 ]]; then
    args+=(wifi.hidden yes)
  fi

  # run the creation command
  run_nmcli "${args[@]}"
  if [[ ${DRY_RUN} -eq 0 ]]; then
    log "Conexión '${CREATE_SSID}' creada. Puedes conectar con --connect ${CREATE_SSID} o activar la autoconexión."
  fi
}

function action_disconnect() {
  if [[ ${DISCONNECT} -eq 0 ]]; then
    return
  fi
  log "Desconectando dispositivo ${DEVICE}..."
  run_nmcli device disconnect "${DEVICE}"
}

function action_forget() {
  if [[ -z "${FORGET_ID}" ]]; then
    return
  fi
  log "Eliminando conexión guardada '${FORGET_ID}'..."
  run_nmcli connection delete "${FORGET_ID}"
}

function reset_action_vars() {
  CONNECT_SSID=""
  CONNECT_PASSWORD=""
  CREATE_SSID=""
  FORGET_ID=""
  DISCONNECT=0
  HIDDEN_NETWORK=0
  ASK_PASSWORD=0
  AUTOCONNECT=0
  RESCAN=0
  NEEDS_PRIVILEGES=0
  DO_STATUS=0
  DO_LIST=0
  DO_LIST_SAVED=0
}

function interactive_menu() {
  ensure_nmcli_available
  detect_wifi_device
  # trap SIGINT within the interactive loop to notify and return to menu
  trap 'echo; echo "Interrupted. Returning to menu." >&2' SIGINT
  while true; do
    echo
    echo "=== NetworkManager Wi-Fi helper (interactive) ==="
    echo "1) Status"
    echo "2) List visible networks (rescan)"
    echo "3) List saved connections"
    echo "4) Connect to SSID"
    echo "5) Create saved connection (offline)"
    echo "6) Disconnect device"
    echo "7) Forget saved connection"
    echo "8) Exit"
    read -rp "Choose an option [1-8]: " opt
    # trim whitespace
    opt="$(echo -n "${opt}" | tr -d '[:space:]')"
    if [[ -z "${opt}" ]]; then
      echo "No input. Please enter a number between 1 and 8."
      continue
    fi
    if ! [[ "${opt}" =~ ^[1-8]$ ]]; then
      echo "Invalid selection: ${opt}. Enter a number between 1 and 8."
      continue
    fi
    case "${opt}" in
      1)
        DO_STATUS=1
        action_status
        DO_STATUS=0
        ;;
      2)
        RESCAN=1
        NEEDS_PRIVILEGES=1
        DO_LIST=1
        maybe_rescan
        action_list_networks
        DO_LIST=0
        RESCAN=0
        NEEDS_PRIVILEGES=0
        ;;
      3)
        DO_LIST_SAVED=1
        action_list_saved
        DO_LIST_SAVED=0
        ;;
      4)
        read -rp "SSID to connect: " CONNECT_SSID
        read -rp "Is it hidden? [y/N]: " a && [[ "${a}" =~ ^[yY] ]] && HIDDEN_NETWORK=1 || HIDDEN_NETWORK=0
        read -rp "Ask for password interactively? [y/N]: " b && [[ "${b}" =~ ^[yY] ]] && ASK_PASSWORD=1 || ASK_PASSWORD=0
        if [[ ${ASK_PASSWORD} -eq 1 ]]; then
          read -rsp "Password: " CONNECT_PASSWORD
          echo
        else
          read -rp "Password (leave blank for open network): " CONNECT_PASSWORD
        fi
        NEEDS_PRIVILEGES=1
        ensure_root_if_needed
        detect_wifi_device
        action_connect
        reset_action_vars
        ;;
      5)
        read -rp "SSID to create: " CREATE_SSID
        read -rp "Hidden network? [y/N]: " c && [[ "${c}" =~ ^[yY] ]] && HIDDEN_NETWORK=1 || HIDDEN_NETWORK=0
        read -rp "Autoconnect? [y/N]: " d && [[ "${d}" =~ ^[yY] ]] && AUTOCONNECT=1 || AUTOCONNECT=0
        read -rp "Ask for password interactively? [y/N]: " e && [[ "${e}" =~ ^[yY] ]] && ASK_PASSWORD=1 || ASK_PASSWORD=0
        if [[ ${ASK_PASSWORD} -eq 1 ]]; then
          read -rsp "Password: " CONNECT_PASSWORD
          echo
        else
          read -rp "Password (leave blank for open network): " CONNECT_PASSWORD
        fi
        NEEDS_PRIVILEGES=1
        ensure_root_if_needed
        detect_wifi_device
        action_create
        reset_action_vars
        ;;
      6)
        NEEDS_PRIVILEGES=1
        ensure_root_if_needed
        detect_wifi_device
        action_disconnect
        reset_action_vars
        ;;
      7)
        read -rp "Connection name or UUID to forget: " FORGET_ID
        NEEDS_PRIVILEGES=1
        ensure_root_if_needed
        action_forget
        reset_action_vars
        ;;
      8)
        echo "Exiting interactive mode."
        # restore default trap behavior
        trap - SIGINT
        break
        ;;
      *)
        echo "Invalid option"
        ;;
    esac
  done
}

if [[ $# -eq 0 && -t 0 ]]; then
  # Interactive terminal and no args: start interactive menu
  interactive_menu
  exit 0
fi

parse_args "$@"
default_actions_if_none
ensure_nmcli_available
detect_wifi_device
maybe_prompt_password
ensure_root_if_needed
log_device_context
maybe_rescan
action_status
action_list_networks
action_list_saved
action_disconnect
action_connect
action_forget
