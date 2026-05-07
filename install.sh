#!/usr/bin/env bash
set -euo pipefail

APP_NAME="checkuser"
INSTALL_DIR="/opt/checkuser-primecel"
BIN_PATH="/usr/local/bin/checkuser"
STARTER_PATH="/usr/local/bin/checkuser-start"
MENU_PATH="/usr/local/bin/checkuser-menu"
ENV_DIR="/etc/checkuser"
ENV_FILE="$ENV_DIR/checkuser.env"
SERVICE_FILE="/etc/systemd/system/checkuser.service"
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

  echo -e "${BLUE}==>${NC} Instalando Go oficial ${GO_VERSION} (${arch})..."
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  else
    wget -qO "$tmp" "$url"
  fi

  if [[ ! -s "$tmp" ]]; then
    echo -e "${RED}Erro ao baixar Go em: $url${NC}"
    exit 1
  fi

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
  echo -e "${BLUE}==>${NC} Instalando dependências..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget ca-certificates tar build-essential sqlite3
}

ensure_go() {
  local cur
  cur="$(current_go_version || true)"
  if [[ -n "$cur" ]] && version_ge "$cur" "$MIN_GO_VERSION"; then
    echo -e "${GREEN}Go encontrado: $cur${NC}"
    return 0
  fi

  if [[ -n "$cur" ]]; then
    echo -e "${YELLOW}Go antigo encontrado: $cur. Mínimo: $MIN_GO_VERSION${NC}"
  else
    echo -e "${YELLOW}Go não encontrado.${NC}"
  fi
  install_official_go
}

copy_sources() {
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$INSTALL_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' "$src_dir/" "$INSTALL_DIR/"
  else
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cp -a "$src_dir/." "$INSTALL_DIR/"
    rm -rf "$INSTALL_DIR/.git"
  fi
}

write_env() {
  mkdir -p "$ENV_DIR" /etc/tg-access-bot
  [[ -f /etc/tg-access-bot/users.jsonl ]] || touch /etc/tg-access-bot/users.jsonl
  [[ -f /etc/tg-access-bot/resellers.json ]] || echo '{}' > /etc/tg-access-bot/resellers.json

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
  echo -e "${BLUE}==>${NC} Compilando CheckUser..."
  cd "$INSTALL_DIR"
  gofmt -w src/data/dao/user_dao.go src/domain/usecase/user/checkuser.go src/infra/handler/user/checkuser.go src/infra/http/route/user.go src/infra/http/echo.go src/data/repository/sqlite_device_repository.go
  go build -ldflags="-w -s" -o "$BIN_PATH" ./src
  chmod +x "$BIN_PATH"
}

write_service() {
  cat > "$STARTER_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/checkuser/checkuser.env ]] && set -a && source /etc/checkuser/checkuser.env && set +a
exec /usr/local/bin/checkuser --start --host "${CHECKUSER_HOST:-0.0.0.0}" --port "${CHECKUSER_PORT:-2052}" ${CHECKUSER_SSL:-}
EOS
  chmod +x "$STARTER_PATH"

  cat > "$SERVICE_FILE" <<'EOS'
[Unit]
Description=CheckUser Go - Primecel DragonCore
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

  cat > "$MENU_PATH" <<EOF_MENU
#!/usr/bin/env bash
sudo bash "$INSTALL_DIR/install.sh"
EOF_MENU
  chmod +x "$MENU_PATH"

  systemctl daemon-reload
  systemctl enable checkuser >/dev/null 2>&1 || true
  systemctl restart checkuser
}

install_checkuser() {
  require_root
  ensure_deps
  ensure_go
  copy_sources
  write_env
  build_binary
  write_service

  echo ""
  echo -e "${GREEN}✅ CheckUser instalado/atualizado com sucesso.${NC}"
  echo -e "Link original: ${CYAN}http://127.0.0.1:2052${NC}"
  echo "Consulta pela raiz: http://127.0.0.1:2052?user=USUARIO"
  echo "Consulta original por rota: http://127.0.0.1:2052/check/USUARIO"
  echo "Consulta compatível: http://127.0.0.1:2052/check?user=USUARIO"
  echo "Com deviceId: http://127.0.0.1:2052?user=USUARIO&deviceid=DEVICE_ID"
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
  journalctl -u checkuser -n 80 --no-pager || true
  pause
}

show_menu() {
  clear
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CHECKUSER PRIMECEL/DRAGONCORE${NC}      ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  if [[ -x "$BIN_PATH" ]]; then
    echo -e "Status: ${GREEN}instalado${NC}"
  else
    echo -e "Status: ${RED}não instalado${NC}"
  fi
  echo ""
  echo "1. Instalar/Atualizar CheckUser"
  echo "2. Reinstalar CheckUser"
  echo "3. Desinstalar CheckUser"
  echo "4. Status"
  echo "5. Logs"
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
      0|00) exit 0 ;;
      *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
