#!/usr/bin/env bash
set -euo pipefail

APP_NAME="checkuser"
REPO_URL="${CHECKUSER_REPO_URL:-https://github.com/yzeusy/checkuser.git}"
BRANCH="${CHECKUSER_BRANCH:-main}"
SRC_DIR="/opt/checkuser-src"
BIN_PATH="/usr/local/bin/checkuser"
STARTER_PATH="/usr/local/bin/checkuser-start"
MENU_PATH="/usr/local/bin/checkuser-menu"
ENV_DIR="/etc/checkuser"
ENV_FILE="$ENV_DIR/checkuser.env"
SERVICE_FILE="/etc/systemd/system/checkuser.service"
LOG_DIR="/var/log/checkuser-installer"
GO_VERSION="${GO_VERSION:-1.22.12}"
MIN_GO_VERSION="${MIN_GO_VERSION:-1.20.0}"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo -e "${RED}Execute como root/sudo.${NC}"
    echo "Exemplo: sudo bash install.sh"
    exit 1
  fi
}

pause() {
  echo ""
  read -r -p "Pressione ENTER para continuar..." _ || true
}

progress() {
  local percent="$1"
  local text="$2"
  local width=30
  local filled=$((percent * width / 100))
  local empty=$((width - filled))
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  printf '\r[%s] %3d%% - %s' "$bar" "$percent" "$text"
  if [[ "$percent" -ge 100 ]]; then
    printf '\n'
  fi
}

version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

current_go_version() {
  if command -v go >/dev/null 2>&1; then
    go version | awk '{print $3}' | sed 's/^go//'
  fi
}

detect_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

install_official_go() {
  local arch tarball url tmp
  arch="$(detect_go_arch)"
  if [[ "$arch" == "unsupported" ]]; then
    echo -e "${RED}Arquitetura não suportada automaticamente: $(uname -m)${NC}"
    exit 1
  fi

  tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  tmp="/tmp/${tarball}"

  progress 20 "baixando Go ${GO_VERSION}"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  else
    wget -qO "$tmp" "$url"
  fi

  if [[ ! -s "$tmp" ]]; then
    echo -e "\n${RED}Erro ao baixar Go em: $url${NC}"
    exit 1
  fi

  progress 35 "instalando Go"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  cat > /etc/profile.d/go.sh <<'EOS'
export PATH=/usr/local/go/bin:$PATH
EOS
  export PATH="/usr/local/go/bin:$PATH"
}

ensure_deps() {
  progress 5 "preparando dependências"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget ca-certificates tar build-essential sqlite3 >/dev/null
}

ensure_go() {
  local cur
  cur="$(current_go_version || true)"
  if [[ -n "$cur" ]] && version_ge "$cur" "$MIN_GO_VERSION"; then
    progress 35 "Go encontrado: $cur"
    return 0
  fi
  install_official_go
}

clone_or_update_repo() {
  progress 45 "baixando CheckUser do GitHub"
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || {
    echo -e "\n${RED}Erro ao clonar: $REPO_URL${NC}"
    exit 1
  }

  if [[ ! -f "$SRC_DIR/go.mod" || ! -d "$SRC_DIR/src" ]]; then
    echo -e "\n${RED}Repositório inválido: go.mod ou pasta src não encontrada.${NC}"
    exit 1
  fi
}

write_env() {
  progress 60 "criando configuração"
  mkdir -p "$ENV_DIR" /etc/tg-access-bot /root
  [[ -f /etc/tg-access-bot/users.jsonl ]] || touch /etc/tg-access-bot/users.jsonl
  [[ -f /etc/tg-access-bot/resellers.json ]] || echo '{}' > /etc/tg-access-bot/resellers.json
  [[ -f /root/usuarios.db ]] || touch /root/usuarios.db

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOS'
CHECKUSER_HOST=0.0.0.0
CHECKUSER_PORT=2052
CHECKUSER_SSL=
CHECKUSER_DB_PATH=/root/db.sqlite3
CHECKUSER_USUARIOS_DB_PATH=/root/usuarios.db
CHECKUSER_BOT_USERS_LOG=/etc/tg-access-bot/users.jsonl
CHECKUSER_BOT_RESELLERS_JSON=/etc/tg-access-bot/resellers.json
DRAGONCORE_MENU_PATH=/opt/DragonCore/menu.php
DRAGONCORE_PHP_BIN=php
EOS
  fi
}

build_binary() {
  progress 75 "compilando CheckUser"
  cd "$SRC_DIR"
  go mod download >/dev/null 2>&1 || true
  go build -ldflags="-w -s" -o "$BIN_PATH" ./src
  chmod +x "$BIN_PATH"
}

write_service_and_menu() {
  progress 88 "criando serviço"
  cat > "$STARTER_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/checkuser/checkuser.env ]] && set -a && source /etc/checkuser/checkuser.env && set +a
exec /usr/local/bin/checkuser --start --host "${CHECKUSER_HOST:-0.0.0.0}" --port "${CHECKUSER_PORT:-2052}" ${CHECKUSER_SSL:-}
EOS
  chmod +x "$STARTER_PATH"

  cat > "$SERVICE_FILE" <<'EOS'
[Unit]
Description=CheckUser Go - Primecel
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/checkuser/checkuser.env
ExecStart=/usr/local/bin/checkuser-start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOS

  cat > "$MENU_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

pause() {
  echo ""
  read -r -p "Pressione ENTER para continuar..." _ || true
}

while true; do
  clear
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC} ${YELLOW}CHECKUSER PRIMECEL${NC}                   ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo "1. Status"
  echo "2. Logs"
  echo "3. Reiniciar serviço"
  echo "4. Testar endpoint"
  echo "5. Editar configuração"
  echo "6. Reinstalar/Atualizar"
  echo "0. Sair"
  echo ""
  read -r -p "Escolha: " opt
  case "$opt" in
    1|01) systemctl status checkuser --no-pager || true; pause ;;
    2|02) journalctl -u checkuser -n 100 --no-pager || true; pause ;;
    3|03) systemctl restart checkuser; echo -e "${GREEN}Serviço reiniciado.${NC}"; pause ;;
    4|04)
      read -r -p "Digite usuário ou UUID: " user
      if [[ -n "$user" ]]; then
        curl -s "http://127.0.0.1:2052?user=${user}" || true
        echo ""
      else
        echo -e "${RED}Usuário vazio.${NC}"
      fi
      pause
      ;;
    5|05) ${EDITOR:-nano} /etc/checkuser/checkuser.env; systemctl restart checkuser || true; pause ;;
    6|06)
      if [[ -x /opt/checkuser-installer/install.sh ]]; then
        sudo bash /opt/checkuser-installer/install.sh
      else
        echo -e "${RED}Instalador local não encontrado em /opt/checkuser-installer/install.sh.${NC}"
        echo "Baixe novamente o instalador e execute: sudo bash install.sh"
        pause
      fi
      ;;
    0|00) exit 0 ;;
    *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
  esac
done
EOS
  chmod +x "$MENU_PATH"

  mkdir -p /opt/checkuser-installer
  local self_path=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  elif [[ -f "$0" ]]; then
    self_path="$0"
  fi

  if [[ -n "$self_path" && -f "$self_path" ]]; then
    cp -f "$self_path" /opt/checkuser-installer/install.sh
    chmod +x /opt/checkuser-installer/install.sh
  else
    cat > /opt/checkuser-installer/install.sh <<'EOS'
#!/usr/bin/env bash
echo "Instalador original não foi copiado porque foi executado via pipe/process substitution."
echo "Baixe novamente o pacote e execute: sudo bash install.sh"
EOS
    chmod +x /opt/checkuser-installer/install.sh
  fi

  systemctl daemon-reload
  systemctl enable checkuser >/dev/null 2>&1
  systemctl restart checkuser
  progress 100 "finalizado"
}

install_checkuser() {
  require_root
  mkdir -p "$LOG_DIR"
  {
    echo "Instalação iniciada em $(date)"
    ensure_deps
    ensure_go
    clone_or_update_repo
    write_env
    build_binary
    write_service_and_menu
  } 2>&1 | tee -a "$LOG_DIR/install.log"

  echo ""
  echo -e "${GREEN}✅ CheckUser instalado/atualizado com sucesso.${NC}"
  echo -e "Link original: ${CYAN}http://127.0.0.1:2052${NC}"
  echo "Consulta: http://127.0.0.1:2052?user=USUARIO"
  echo "Consulta UUID: http://127.0.0.1:2052?user=UUID_DO_XRAY"
  echo "Menu: checkuser-menu"
  pause
}

uninstall_checkuser() {
  require_root
  systemctl stop checkuser >/dev/null 2>&1 || true
  systemctl disable checkuser >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$STARTER_PATH" "$BIN_PATH" "$MENU_PATH"
  systemctl daemon-reload
  echo -e "${GREEN}CheckUser removido.${NC}"
  pause
}

show_status() {
  systemctl status checkuser --no-pager || true
  pause
}

show_logs() {
  journalctl -u checkuser -n 100 --no-pager || true
  pause
}

test_endpoint() {
  echo ""
  read -r -p "Digite usuário ou UUID para testar: " test_user
  if [[ -z "$test_user" ]]; then
    echo -e "${RED}Usuário vazio.${NC}"
  else
    curl -s "http://127.0.0.1:2052?user=${test_user}" || true
    echo ""
  fi
  pause
}

show_menu() {
  clear
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC} ${YELLOW}CHECKUSER PRIMECEL - DIRETO${NC}          ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo "Repo: $REPO_URL"
  echo "Porta: 2052"
  echo ""
  echo "1. Instalar/Atualizar CheckUser"
  echo "2. Reinstalar CheckUser"
  echo "3. Desinstalar CheckUser"
  echo "4. Status"
  echo "5. Logs"
  echo "6. Testar endpoint"
  echo "0. Sair"
  echo ""
  echo -n "Escolha: "
}

main() {
  while true; do
    show_menu
    read -r opt
    case "$opt" in
      1|01) install_checkuser ;;
      2|02) uninstall_checkuser; install_checkuser ;;
      3|03) uninstall_checkuser ;;
      4|04) show_status ;;
      5|05) show_logs ;;
      6|06) test_endpoint ;;
      0|00) exit 0 ;;
      *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
