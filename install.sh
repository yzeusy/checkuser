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

get_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
      ip="$(curl -4 -fsS --max-time 4 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "$ip"
}


normalize_public_host_env() {
  local detected current
  detected="$(get_public_ip)"
  [[ -f "$ENV_FILE" ]] || return 0

  current="$(grep -E '^CHECKUSER_PUBLIC_HOST=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"

  # Se ficou placeholder de instalação anterior, vazio, localhost ou loopback, troca pelo IP público detectado.
  if [[ -n "$detected" ]]; then
    if [[ -z "$current" || "$current" == "SEU_IP_PUBLICO" || "$current" == "IP_DA_VPS" || "$current" == "IP_PUBLICO_DA_VPS" || "$current" == "127.0.0.1" || "$current" == "localhost" ]]; then
      if grep -qE '^CHECKUSER_PUBLIC_HOST=' "$ENV_FILE"; then
        sed -i "s|^CHECKUSER_PUBLIC_HOST=.*|CHECKUSER_PUBLIC_HOST=${detected}|" "$ENV_FILE"
      else
        echo "CHECKUSER_PUBLIC_HOST=${detected}" >> "$ENV_FILE"
      fi
    fi
  fi
}

is_placeholder_host() {
  local host="$1"
  [[ -z "$host" || "$host" == "SEU_IP_PUBLICO" || "$host" == "IP_DA_VPS" || "$host" == "IP_PUBLICO_DA_VPS" || "$host" == "127.0.0.1" || "$host" == "localhost" ]]
}


normalize_domain_input() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%\?*}"
  value="${value%%:*}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  printf '%s' "$value"
}

set_env_key() {
  local key="$1"
  local value="$2"
  mkdir -p "$ENV_DIR"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

get_cloudflare_url() {
  local domain=""
  if [[ -f "$ENV_FILE" ]]; then
    domain="$(grep -E '^CHECKUSER_CLOUDFLARE_DOMAIN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  if [[ -n "$domain" ]]; then
    printf 'https://%s' "$domain"
  fi
}

open_checkuser_port_if_possible() {
  # O CheckUser escuta em 0.0.0.0:2052. Aqui liberamos a porta no firewall local quando o UFW estiver ativo.
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow 2052/tcp >/dev/null 2>&1 || true
    fi
  fi
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget ca-certificates tar build-essential sqlite3 jq python3 >/dev/null
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
CHECKUSER_PUBLIC_HOST=
CHECKUSER_SSL=
CHECKUSER_CLOUDFLARE_DOMAIN=
CHECKUSER_CLOUDFLARE_URL=
CHECKUSER_CLOUDFLARE_API_TOKEN=
CHECKUSER_DB_PATH=/root/db.sqlite3
CHECKUSER_USUARIOS_DB_PATH=/root/usuarios.db
CHECKUSER_BOT_USERS_LOG=/etc/tg-access-bot/users.jsonl
CHECKUSER_BOT_RESELLERS_JSON=/etc/tg-access-bot/resellers.json
DRAGONCORE_MENU_PATH=/opt/DragonCore/menu.php
DRAGONCORE_PHP_BIN=php
EOS
  fi
}

apply_expiration_hours_patch() {
  progress 55 "ajustando validade em horas/dias"
  cd "$SRC_DIR"

  python3 <<'PYEOF'
from pathlib import Path

base = Path('.')
helper = base / 'src/domain/usecase/user/expiration_format.go'
helper.write_text("""package user_use_case

import (
	\"fmt\"
	\"math\"
	\"time\"
)

func expirationRemainingInfo(expiresAt time.Time) (string, int, string) {
	remaining := time.Until(expiresAt)
	if remaining <= 0 {
		return \"expirado\", 0, \"expired\"
	}

	hours := int(math.Ceil(remaining.Hours()))
	if hours < 1 {
		hours = 1
	}

	// Acessos de horas devem aparecer como horas.
	// 2h, 4h, 8h e 24h ficam como horas.
	// Acima de 24h, mostra em dias.
	if hours <= 24 {
		return fmt.Sprintf(\"%dh\", hours), hours, \"hours\"
	}

	days := int(math.Ceil(remaining.Hours() / 24))
	if days < 1 {
		days = 1
	}

	if days == 1 {
		return \"1 dia\", days, \"days\"
	}

	return fmt.Sprintf(\"%d dias\", days), days, \"days\"
}
""")


def patch_checkuser_go(path: Path):
    if not path.exists():
        return
    s = path.read_text()
    if 'ExpiresIn' not in s:
        s = s.replace('ExpiresDays int    `json:"expiration_days"`', 'ExpiresDays int    `json:"expiration_days"`\n\tExpiresIn   string `json:"expires_in"`\n\tRemaining   string `json:"expiration_remaining"`\n\tDisplay     string `json:"expiration_display"`\n\tRemainValue int    `json:"expiration_value"`\n\tRemainUnit  string `json:"expiration_unit"`')
    if 'expirationRemainingInfo(user.ExpiresAt)' not in s:
        ret = 'return &CheckUserOutput{\n\t\tID:'
        if ret in s:
            s = s.replace(ret, 'remainingLabel, remainingValue, remainingUnit := expirationRemainingInfo(user.ExpiresAt)\n\n\treturn &CheckUserOutput{\n\t\tID:', 1)
    old = 'ExpiresDays: int(time.Until(user.ExpiresAt).Hours() / 24),'
    new = 'ExpiresDays: int(time.Until(user.ExpiresAt).Hours() / 24),\n\t\tExpiresIn:   remainingLabel,\n\t\tRemaining:   remainingLabel,\n\t\tDisplay:     remainingLabel,\n\t\tRemainValue: remainingValue,\n\t\tRemainUnit:  remainingUnit,'
    if old in s and 'ExpiresIn:   remainingLabel' not in s:
        s = s.replace(old, new, 1)
    path.write_text(s)


def patch_details_go(path: Path):
    if not path.exists():
        return
    s = path.read_text()
    if 'ExpiresIn' not in s:
        s = s.replace('ExpiresDays int    `json:"expires_days"`', 'ExpiresDays int    `json:"expires_days"`\n\tExpiresIn   string `json:"expires_in"`\n\tRemaining   string `json:"expiration_remaining"`\n\tDisplay     string `json:"expiration_display"`\n\tRemainValue int    `json:"expiration_value"`\n\tRemainUnit  string `json:"expiration_unit"`')
    if 'expirationRemainingInfo(user.ExpiresAt)' not in s:
        ret = 'return &DetailUserOutput{\n\t\tID:'
        if ret in s:
            s = s.replace(ret, 'remainingLabel, remainingValue, remainingUnit := expirationRemainingInfo(user.ExpiresAt)\n\n\treturn &DetailUserOutput{\n\t\tID:', 1)
    old = 'ExpiresDays: int(time.Until(user.ExpiresAt).Hours() / 24),'
    new = 'ExpiresDays: int(time.Until(user.ExpiresAt).Hours() / 24),\n\t\tExpiresIn:   remainingLabel,\n\t\tRemaining:   remainingLabel,\n\t\tDisplay:     remainingLabel,\n\t\tRemainValue: remainingValue,\n\t\tRemainUnit:  remainingUnit,'
    if old in s and 'ExpiresIn:   remainingLabel' not in s:
        s = s.replace(old, new, 1)
    path.write_text(s)


def patch_index_html(path: Path):
    if not path.exists():
        return
    s = path.read_text()
    s = s.replace("expiresAtElement.innerHTML = data.expires_at ?? ''", "expiresAtElement.innerHTML = data.expires_in ?? data.expires_at ?? ''")
    path.write_text(s)

patch_checkuser_go(base / 'src/domain/usecase/user/checkuser.go')
patch_details_go(base / 'src/domain/usecase/user/details.go')
patch_index_html(base / 'src/infra/http/index_html.go')
PYEOF

  if command -v gofmt >/dev/null 2>&1; then
    gofmt -w src/domain/usecase/user/expiration_format.go src/domain/usecase/user/checkuser.go src/domain/usecase/user/details.go 2>/dev/null || true
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
ENV_FILE="/etc/checkuser/checkuser.env"

pause() {
  echo ""
  read -r -p "Pressione ENTER para continuar..." _ || true
}

installed_status_text() {
  if [[ -x /usr/local/bin/checkuser && -f /etc/systemd/system/checkuser.service ]]; then
    echo -e "${GREEN}Instalado${NC}"
  else
    echo -e "${RED}Não instalado${NC}"
  fi
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

get_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
      ip="$(curl -4 -fsS --max-time 4 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "$ip"
}

normalize_domain_input() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%\?*}"
  value="${value%%:*}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  printf '%s' "$value"
}

set_env_key() {
  local key="$1"
  local value="$2"
  mkdir -p /etc/checkuser
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

get_cloudflare_url() {
  local domain=""
  if [[ -f "$ENV_FILE" ]]; then
    domain="$(grep -E '^CHECKUSER_CLOUDFLARE_DOMAIN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  if [[ -n "$domain" ]]; then
    printf 'https://%s' "$domain"
  fi
}

configure_cloudflare_menu() {
  local ip domain cf_url
  ip="$(get_public_ip)"
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CONFIGURAR CLOUDFLARE${NC}                ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Use domínio/subdomínio, exemplo: check.seudominio.com"
  echo "O link final será: https://dominio.com/?user=USUARIO"
  echo ""
  read -r -p "Domínio/Subdomínio: " domain
  domain="$(normalize_domain_input "$domain")"
  if [[ -z "$domain" || "$domain" != *.* ]]; then
    echo -e "${RED}Domínio inválido.${NC}"
    pause
    return
  fi
  cf_url="https://${domain}"
  set_env_key CHECKUSER_CLOUDFLARE_DOMAIN "$domain"
  set_env_key CHECKUSER_CLOUDFLARE_URL "$cf_url"
  set_env_key CHECKUSER_PUBLIC_HOST "$domain"
  echo ""
  echo -e "${GREEN}Configuração local salva.${NC}"
  echo ""
  echo -e "${YELLOW}Configure na Cloudflare:${NC}"
  echo "1. DNS → A → ${domain} → ${ip:-IP_PUBLICO_DA_VPS} → Proxy ativado"
  echo "2. Rules → Origin Rules → Create rule"
  echo "   Expressão: http.host eq "${domain}""
  echo "   Destination Port: Rewrite to 2052"
  echo "3. Link do app: ${cf_url}/?user=USUARIO"
  echo "4. UUID: ${cf_url}/?user=UUID_DO_XRAY"
  echo ""
  echo -e "${YELLOW}Atenção:${NC} se o CheckUser estiver em HTTP puro na origem, use modo SSL compatível com HTTP até a origem ou proxy local/Nginx."
  pause
}

clear_deviceid() {
  load_env
  local db="${CHECKUSER_DB_PATH:-/root/db.sqlite3}"
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}LIMPAR DEVICEID${NC}                      ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo -e "${RED}sqlite3 não encontrado. Instale com: apt install sqlite3 -y${NC}"
    pause
    return
  fi

  if [[ ! -f "$db" ]]; then
    echo -e "${RED}Banco do CheckUser não encontrado:${NC} $db"
    pause
    return
  fi

  if ! sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='devices';" | grep -qx devices; then
    echo -e "${YELLOW}Tabela devices ainda não existe nesse banco.${NC}"
    echo "Ela será criada pelo CheckUser quando houver primeiro uso com deviceid."
    pause
    return
  fi

  echo "1. Limpar DeviceID de um usuário"
  echo "2. Limpar DeviceID de todos"
  echo "0. Voltar"
  echo ""
  read -r -p "Escolha: " opt

  case "$opt" in
    1|01)
      read -r -p "Usuário: " username
      if [[ -z "$username" ]]; then
        echo -e "${RED}Usuário vazio.${NC}"
        pause
        return
      fi
      local escaped count
      escaped="$(sql_escape "$username")"
      count="$(sqlite3 "$db" "SELECT COUNT(*) FROM devices WHERE username='${escaped}';" 2>/dev/null || echo 0)"
      sqlite3 "$db" "DELETE FROM devices WHERE username='${escaped}';" >/dev/null
      echo -e "${GREEN}DeviceID limpo para ${username}.${NC} Removidos: ${count}"
      pause
      ;;
    2|02)
      read -r -p "Digite SIM para limpar todos os DeviceIDs: " confirm
      if [[ "$confirm" != "SIM" ]]; then
        echo -e "${YELLOW}Operação cancelada.${NC}"
        pause
        return
      fi
      local count
      count="$(sqlite3 "$db" "SELECT COUNT(*) FROM devices;" 2>/dev/null || echo 0)"
      sqlite3 "$db" "DELETE FROM devices;" >/dev/null
      echo -e "${GREEN}Todos os DeviceIDs foram limpos.${NC} Removidos: ${count}"
      pause
      ;;
    0|00) return ;;
    *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
  esac
}

test_endpoint_menu() {
  read -r -p "Digite usuário ou UUID: " user
  if [[ -n "$user" ]]; then
    echo -e "${CYAN}Local:${NC} http://127.0.0.1:2052?user=${user}"
    curl -s "http://127.0.0.1:2052?user=${user}" || true
    echo ""
    cf_url="$(get_cloudflare_url)"
    if [[ -n "$cf_url" ]]; then
      echo -e "${CYAN}Cloudflare:${NC} ${cf_url}/?user=${user}"
    fi
  else
    echo -e "${RED}Usuário vazio.${NC}"
  fi
  pause
}



cf_api_request() {
  local token="$1"
  local method="$2"
  local endpoint="$3"
  local data="${4:-}"
  local url="https://api.cloudflare.com/client/v4${endpoint}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

cf_require_success() {
  local response="$1"
  local label="$2"
  local ok
  ok="$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "$ok" != "true" ]]; then
    echo -e "${RED}Falha: ${label}.${NC}"
    printf '%s' "$response" | jq -r '(.errors // [])[] | "- " + (.message // tostring)' 2>/dev/null || true
    return 1
  fi
  return 0
}

read_cf_token() {
  local saved=""
  if [[ -f "$ENV_FILE" ]]; then
    saved="$(grep -E '^CHECKUSER_CLOUDFLARE_API_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi

  if [[ -n "$saved" ]]; then
    read -r -p "Usar token Cloudflare salvo? [S/n]: " use_saved
    if [[ -z "$use_saved" || "$use_saved" =~ ^[Ss]$ ]]; then
      printf '%s' "$saved"
      return 0
    fi
  fi

  local token=""
  read -r -s -p "Token API Cloudflare: " token
  echo ""
  if [[ -z "$token" ]]; then
    echo -e "${RED}Token vazio.${NC}" >&2
    return 1
  fi
  read -r -p "Salvar token nesta VPS para próximas configurações? [S/n]: " save_token
  if [[ -z "$save_token" || "$save_token" =~ ^[Ss]$ ]]; then
    set_env_key CHECKUSER_CLOUDFLARE_API_TOKEN "$token"
  fi
  printf '%s' "$token"
}

build_cf_hostname() {
  local zone_name="$1"
  local sub="$2"
  sub="$(printf '%s' "$sub" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  sub="${sub#http://}"
  sub="${sub#https://}"
  sub="${sub%%/*}"
  sub="${sub%%\?*}"
  sub="${sub%%:*}"

  if [[ -z "$sub" || "$sub" == "@" ]]; then
    printf '%s' "$zone_name"
  elif [[ "$sub" == *.* ]]; then
    if [[ "$sub" == "$zone_name" || "$sub" == *".${zone_name}" ]]; then
      printf '%s' "$sub"
    else
      return 1
    fi
  else
    printf '%s.%s' "$sub" "$zone_name"
  fi
}

cf_create_or_update_dns() {
  local token="$1"
  local zone_id="$2"
  local fqdn="$3"
  local ip="$4"
  local response record_id body

  response="$(cf_api_request "$token" GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}")"
  cf_require_success "$response" "consultar DNS" || return 1
  record_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"

  body="$(jq -n --arg name "$fqdn" --arg content "$ip" '{type:"A", name:$name, content:$content, ttl:1, proxied:true}')"
  if [[ -n "$record_id" ]]; then
    response="$(cf_api_request "$token" PUT "/zones/${zone_id}/dns_records/${record_id}" "$body")"
    cf_require_success "$response" "atualizar DNS" || return 1
    echo -e "${GREEN}DNS atualizado:${NC} ${fqdn} → ${ip} / proxy ativo"
  else
    response="$(cf_api_request "$token" POST "/zones/${zone_id}/dns_records" "$body")"
    cf_require_success "$response" "criar DNS" || return 1
    echo -e "${GREEN}DNS criado:${NC} ${fqdn} → ${ip} / proxy ativo"
  fi
}

cf_create_or_update_origin_rule() {
  local token="$1"
  local zone_id="$2"
  local fqdn="$3"
  local rulesets ruleset_id response full ref body

  rulesets="$(cf_api_request "$token" GET "/zones/${zone_id}/rulesets")"
  cf_require_success "$rulesets" "listar regras de origem" || return 1
  ruleset_id="$(printf '%s' "$rulesets" | jq -r '.result[] | select(.phase=="http_request_origin" and .kind=="zone") | .id' | head -n1)"

  if [[ -z "$ruleset_id" ]]; then
    body='{"name":"CheckUser DTunnel Origin Rules","kind":"zone","phase":"http_request_origin","rules":[]}'
    response="$(cf_api_request "$token" POST "/zones/${zone_id}/rulesets" "$body")"
    cf_require_success "$response" "criar ruleset de origem" || return 1
    ruleset_id="$(printf '%s' "$response" | jq -r '.result.id')"
  fi

  full="$(cf_api_request "$token" GET "/zones/${zone_id}/rulesets/${ruleset_id}")"
  cf_require_success "$full" "ler ruleset de origem" || return 1
  ref="checkuser_dtunnel_$(printf '%s' "$fqdn" | sed 's/[^A-Za-z0-9_]/_/g')"

  body="$(printf '%s' "$full" | jq --arg fqdn "$fqdn" --arg ref "$ref" '
    .result.rules as $rules |
    {
      rules: (
        ($rules // [] | map(select((.ref // "") != $ref and (.description // "") != ("CheckUser DTunnel - " + $fqdn) and (.expression // "") != ("http.host eq \"" + $fqdn + "\""))))
        + [{
          ref: $ref,
          expression: ("http.host eq \"" + $fqdn + "\""),
          description: ("CheckUser DTunnel - " + $fqdn),
          action: "route",
          action_parameters: { origin: { port: 2052 } }
        }]
      )
    }
  ')"

  response="$(cf_api_request "$token" PUT "/zones/${zone_id}/rulesets/${ruleset_id}" "$body")"
  cf_require_success "$response" "criar/atualizar Origin Rule" || return 1
  echo -e "${GREEN}Origin Rule criada/atualizada:${NC} ${fqdn} → porta 2052"
}

configure_cloudflare_menu() {
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CLOUDFLARE AUTOMÁTICO${NC}                ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Permissões necessárias no token: Zone Read, DNS Edit e Rulesets/Origin Write."
  echo ""

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}Instalando jq...${NC}"
    apt-get update -y >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null
  fi

  local token zones count choice idx zone_id zone_name sub fqdn ip response cf_url
  token="$(read_cf_token)" || { pause; return; }

  zones="$(cf_api_request "$token" GET "/zones?per_page=100")"
  cf_require_success "$zones" "conectar/listar domínios da Cloudflare" || { pause; return; }
  count="$(printf '%s' "$zones" | jq '.result | length')"
  if [[ "$count" -lt 1 ]]; then
    echo -e "${RED}Nenhum domínio encontrado nessa conta/token.${NC}"
    pause
    return
  fi

  echo -e "${CYAN}Domínios encontrados:${NC}"
  printf '%s' "$zones" | jq -r '.result | to_entries[] | "\(.key + 1). \(.value.name)"'
  echo ""
  read -r -p "Escolha o domínio: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$count" ]]; then
    echo -e "${RED}Opção inválida.${NC}"
    pause
    return
  fi

  idx=$((choice - 1))
  zone_id="$(printf '%s' "$zones" | jq -r ".result[$idx].id")"
  zone_name="$(printf '%s' "$zones" | jq -r ".result[$idx].name")"

  echo ""
  echo "Digite o subdomínio. Exemplos: check, api, vpn"
  echo "Deixe vazio ou use @ para usar o domínio raiz: ${zone_name}"
  read -r -p "Subdomínio: " sub
  fqdn="$(build_cf_hostname "$zone_name" "$sub")" || {
    echo -e "${RED}Subdomínio inválido para a zona ${zone_name}.${NC}"
    pause
    return
  }

  if ! [[ "$fqdn" =~ ^[a-z0-9.-]+$ ]]; then
    echo -e "${RED}Host inválido: ${fqdn}${NC}"
    pause
    return
  fi

  ip="$(get_public_ip)"
  if [[ -z "$ip" ]]; then
    read -r -p "IP público da VPS: " ip
  else
    read -r -p "IP público detectado (${ip}). Pressione ENTER para usar ou digite outro: " response
    [[ -n "$response" ]] && ip="$response"
  fi

  if [[ -z "$ip" ]]; then
    echo -e "${RED}IP público vazio.${NC}"
    pause
    return
  fi

  cf_create_or_update_dns "$token" "$zone_id" "$fqdn" "$ip" || { pause; return; }
  cf_create_or_update_origin_rule "$token" "$zone_id" "$fqdn" || { pause; return; }

  cf_url="https://${fqdn}"
  set_env_key CHECKUSER_CLOUDFLARE_DOMAIN "$fqdn"
  set_env_key CHECKUSER_CLOUDFLARE_URL "$cf_url"
  set_env_key CHECKUSER_PUBLIC_HOST "$fqdn"

  echo ""
  echo -e "${GREEN}✅ Cloudflare configurado com sucesso.${NC}"
  echo "Link do app: ${cf_url}/?user="
  echo "Teste: ${cf_url}/?user=USUARIO"
  echo "UUID:  ${cf_url}/?user=UUID_DO_XRAY"
  echo ""
  echo -e "${YELLOW}Observação:${NC} se usar HTTPS no domínio e o CheckUser estiver em HTTP puro, confira o modo SSL da Cloudflare ou use proxy local/Nginx."
  pause
}

while true; do
  clear
  installed="$(installed_status_text)"

  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CHECKUSER DTUNNEL${NC}                    ${CYAN}║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC} Status: ${installed}"
  echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC} ${GREEN}1${NC}. Reiniciar serviço"
  echo -e "${CYAN}║${NC} ${GREEN}2${NC}. Limpar DeviceID"
  echo -e "${CYAN}║${NC} ${GREEN}3${NC}. Testar endpoint"
  echo -e "${CYAN}║${NC} ${GREEN}4${NC}. Editar configuração"
  echo -e "${CYAN}║${NC} ${GREEN}5${NC}. Reinstalar/Atualizar"
  echo -e "${CYAN}║${NC} ${GREEN}6${NC}. Configurar Cloudflare automático"
  echo -e "${CYAN}║${NC} ${RED}0${NC}. Sair"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  read -r -p "Escolha: " opt
  case "$opt" in
    1|01) systemctl restart checkuser; echo -e "${GREEN}Serviço reiniciado.${NC}"; pause ;;
    2|02) clear_deviceid ;;
    3|03) test_endpoint_menu ;;
    4|04) ${EDITOR:-nano} /etc/checkuser/checkuser.env; systemctl restart checkuser || true; pause ;;
    5|05)
      if [[ -x /opt/checkuser-installer/install.sh ]]; then
        sudo bash /opt/checkuser-installer/install.sh
      else
        echo -e "${RED}Instalador local não encontrado em /opt/checkuser-installer/install.sh.${NC}"
        echo "Baixe novamente o instalador e execute: sudo bash install.sh"
        pause
      fi
      ;;
    6|06) configure_cloudflare_menu ;;
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

  open_checkuser_port_if_possible
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
    apply_expiration_hours_patch
    write_env
    normalize_public_host_env
    build_binary
    write_service_and_menu
  } 2>&1 | tee -a "$LOG_DIR/install.log"

  local public_ip public_host cloudflare_url
  public_ip="$(get_public_ip)"
  cloudflare_url="$(get_cloudflare_url)"
  public_host="$public_ip"
  if [[ -f "$ENV_FILE" ]]; then
    local configured_public
    configured_public="$(grep -E '^CHECKUSER_PUBLIC_HOST=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    if [[ -n "$configured_public" ]] && ! is_placeholder_host "$configured_public"; then
      public_host="$configured_public"
    elif is_placeholder_host "$configured_public"; then
      public_host="$public_ip"
    fi
  fi

  echo ""
  echo -e "${GREEN}✅ CheckUser instalado/atualizado com sucesso.${NC}"
  echo -e "Local: ${CYAN}http://127.0.0.1:2052${NC}"
  if [[ -n "$cloudflare_url" ]]; then
    echo -e "Cloudflare: ${CYAN}${cloudflare_url}${NC}"
    echo "Consulta: ${cloudflare_url}?user=USUARIO"
    echo "Consulta UUID: ${cloudflare_url}?user=UUID_DO_XRAY"
  elif [[ -n "$public_host" ]]; then
    echo -e "Público: ${CYAN}http://${public_host}:2052${NC}"
    echo "Consulta: http://${public_host}:2052?user=USUARIO"
    echo "Consulta UUID: http://${public_host}:2052?user=UUID_DO_XRAY"
  else
    echo -e "${YELLOW}IP público não detectado automaticamente.${NC}"
    echo "Consulta pública: http://IP_DA_VPS:2052?user=USUARIO"
  fi
  echo "Menu: checkuser-menu"
  echo ""
  echo -e "${YELLOW}Observação:${NC} se a VPS estiver em AWS/Oracle/Google/Hostinger, libere a porta 2052 no firewall/security group da nuvem."
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
    echo -e "${CYAN}Teste local:${NC} http://127.0.0.1:2052?user=${test_user}"
    curl -s "http://127.0.0.1:2052?user=${test_user}" || true
    echo ""
    public_ip="$(get_public_ip)"
    if [[ -f "$ENV_FILE" ]]; then
      configured_public="$(grep -E '^CHECKUSER_PUBLIC_HOST=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
      if [[ -n "$configured_public" ]] && ! is_placeholder_host "$configured_public"; then
        public_ip="$configured_public"
      fi
    fi
    cloudflare_url="$(get_cloudflare_url)"
    if [[ -n "$cloudflare_url" ]]; then
      echo -e "${CYAN}Link Cloudflare:${NC} ${cloudflare_url}?user=${test_user}"
    elif [[ -n "$public_ip" ]]; then
      echo -e "${CYAN}Link público:${NC} http://${public_ip}:2052?user=${test_user}"
    fi
  fi
  pause
}


load_checkuser_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

clear_deviceid() {
  require_root
  load_checkuser_env
  local db="${CHECKUSER_DB_PATH:-/root/db.sqlite3}"
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}LIMPAR DEVICEID${NC}                      ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo -e "${RED}sqlite3 não encontrado. Instale com: apt install sqlite3 -y${NC}"
    pause
    return
  fi

  if [[ ! -f "$db" ]]; then
    echo -e "${RED}Banco do CheckUser não encontrado:${NC} $db"
    pause
    return
  fi

  if ! sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='devices';" | grep -qx devices; then
    echo -e "${YELLOW}Tabela devices ainda não existe nesse banco.${NC}"
    echo "Ela será criada pelo CheckUser quando houver primeiro uso com deviceid."
    pause
    return
  fi

  echo "1. Limpar DeviceID de um usuário"
  echo "2. Limpar DeviceID de todos"
  echo "0. Voltar"
  echo ""
  read -r -p "Escolha: " opt

  case "$opt" in
    1|01)
      read -r -p "Usuário: " username
      if [[ -z "$username" ]]; then
        echo -e "${RED}Usuário vazio.${NC}"
        pause
        return
      fi
      local escaped count
      escaped="$(sql_escape "$username")"
      count="$(sqlite3 "$db" "SELECT COUNT(*) FROM devices WHERE username='${escaped}';" 2>/dev/null || echo 0)"
      sqlite3 "$db" "DELETE FROM devices WHERE username='${escaped}';" >/dev/null
      echo -e "${GREEN}DeviceID limpo para ${username}.${NC} Removidos: ${count}"
      pause
      ;;
    2|02)
      read -r -p "Digite SIM para limpar todos os DeviceIDs: " confirm
      if [[ "$confirm" != "SIM" ]]; then
        echo -e "${YELLOW}Operação cancelada.${NC}"
        pause
        return
      fi
      local count
      count="$(sqlite3 "$db" "SELECT COUNT(*) FROM devices;" 2>/dev/null || echo 0)"
      sqlite3 "$db" "DELETE FROM devices;" >/dev/null
      echo -e "${GREEN}Todos os DeviceIDs foram limpos.${NC} Removidos: ${count}"
      pause
      ;;
    0|00) return ;;
    *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
  esac
}


configure_cloudflare() {
  require_root
  clear
  local ip domain cf_url
  ip="$(get_public_ip)"

  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CONFIGURAR CLOUDFLARE${NC}                ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Use um domínio ou subdomínio, exemplo: check.seudominio.com"
  echo "O link final ficará assim: https://dominio.com/?user=USUARIO"
  echo ""
  read -r -p "Domínio/Subdomínio: " domain
  domain="$(normalize_domain_input "$domain")"

  if [[ -z "$domain" || "$domain" != *.* ]]; then
    echo -e "${RED}Domínio inválido.${NC}"
    pause
    return
  fi

  cf_url="https://${domain}"
  set_env_key "CHECKUSER_CLOUDFLARE_DOMAIN" "$domain"
  set_env_key "CHECKUSER_CLOUDFLARE_URL" "$cf_url"
  set_env_key "CHECKUSER_PUBLIC_HOST" "$domain"

  echo ""
  echo -e "${GREEN}Configuração local salva.${NC}"
  echo ""
  echo -e "${YELLOW}Agora configure no painel da Cloudflare:${NC}"
  echo ""
  echo "1. DNS"
  echo "   Tipo: A"
  echo "   Nome: ${domain}"
  echo "   IPv4: ${ip:-IP_PUBLICO_DA_VPS}"
  echo "   Proxy: Ativado / nuvem laranja"
  echo ""
  echo "2. Rules → Origin Rules → Create rule"
  echo "   Nome: CheckUser DTunnel"
  echo "   Expressão: http.host eq \"${domain}\""
  echo "   Destination Port: Rewrite to 2052"
  echo ""
  echo "3. Link para usar no app"
  echo "   ${cf_url}/?user=USUARIO"
  echo "   ${cf_url}/?user=UUID_DO_XRAY"
  echo ""
  echo -e "${YELLOW}Importante:${NC} se seu CheckUser estiver em HTTP puro na porta 2052, o modo SSL da Cloudflare precisa permitir conexão HTTP até a origem ou você deve usar um proxy local como Nginx."
  pause
}



cf_api_request() {
  local token="$1"
  local method="$2"
  local endpoint="$3"
  local data="${4:-}"
  local url="https://api.cloudflare.com/client/v4${endpoint}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

cf_require_success() {
  local response="$1"
  local label="$2"
  local ok
  ok="$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "$ok" != "true" ]]; then
    echo -e "${RED}Falha: ${label}.${NC}"
    printf '%s' "$response" | jq -r '(.errors // [])[] | "- " + (.message // tostring)' 2>/dev/null || true
    return 1
  fi
  return 0
}

read_cf_token() {
  local saved=""
  if [[ -f "$ENV_FILE" ]]; then
    saved="$(grep -E '^CHECKUSER_CLOUDFLARE_API_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi

  if [[ -n "$saved" ]]; then
    read -r -p "Usar token Cloudflare salvo? [S/n]: " use_saved
    if [[ -z "$use_saved" || "$use_saved" =~ ^[Ss]$ ]]; then
      printf '%s' "$saved"
      return 0
    fi
  fi

  local token=""
  read -r -s -p "Token API Cloudflare: " token
  echo ""
  if [[ -z "$token" ]]; then
    echo -e "${RED}Token vazio.${NC}" >&2
    return 1
  fi
  read -r -p "Salvar token nesta VPS para próximas configurações? [S/n]: " save_token
  if [[ -z "$save_token" || "$save_token" =~ ^[Ss]$ ]]; then
    set_env_key CHECKUSER_CLOUDFLARE_API_TOKEN "$token"
  fi
  printf '%s' "$token"
}

build_cf_hostname() {
  local zone_name="$1"
  local sub="$2"
  sub="$(printf '%s' "$sub" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  sub="${sub#http://}"
  sub="${sub#https://}"
  sub="${sub%%/*}"
  sub="${sub%%\?*}"
  sub="${sub%%:*}"

  if [[ -z "$sub" || "$sub" == "@" ]]; then
    printf '%s' "$zone_name"
  elif [[ "$sub" == *.* ]]; then
    if [[ "$sub" == "$zone_name" || "$sub" == *".${zone_name}" ]]; then
      printf '%s' "$sub"
    else
      return 1
    fi
  else
    printf '%s.%s' "$sub" "$zone_name"
  fi
}

cf_create_or_update_dns() {
  local token="$1"
  local zone_id="$2"
  local fqdn="$3"
  local ip="$4"
  local response record_id body

  response="$(cf_api_request "$token" GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}")"
  cf_require_success "$response" "consultar DNS" || return 1
  record_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"

  body="$(jq -n --arg name "$fqdn" --arg content "$ip" '{type:"A", name:$name, content:$content, ttl:1, proxied:true}')"
  if [[ -n "$record_id" ]]; then
    response="$(cf_api_request "$token" PUT "/zones/${zone_id}/dns_records/${record_id}" "$body")"
    cf_require_success "$response" "atualizar DNS" || return 1
    echo -e "${GREEN}DNS atualizado:${NC} ${fqdn} → ${ip} / proxy ativo"
  else
    response="$(cf_api_request "$token" POST "/zones/${zone_id}/dns_records" "$body")"
    cf_require_success "$response" "criar DNS" || return 1
    echo -e "${GREEN}DNS criado:${NC} ${fqdn} → ${ip} / proxy ativo"
  fi
}

cf_create_or_update_origin_rule() {
  local token="$1"
  local zone_id="$2"
  local fqdn="$3"
  local rulesets ruleset_id response full ref body

  rulesets="$(cf_api_request "$token" GET "/zones/${zone_id}/rulesets")"
  cf_require_success "$rulesets" "listar regras de origem" || return 1
  ruleset_id="$(printf '%s' "$rulesets" | jq -r '.result[] | select(.phase=="http_request_origin" and .kind=="zone") | .id' | head -n1)"

  if [[ -z "$ruleset_id" ]]; then
    body='{"name":"CheckUser DTunnel Origin Rules","kind":"zone","phase":"http_request_origin","rules":[]}'
    response="$(cf_api_request "$token" POST "/zones/${zone_id}/rulesets" "$body")"
    cf_require_success "$response" "criar ruleset de origem" || return 1
    ruleset_id="$(printf '%s' "$response" | jq -r '.result.id')"
  fi

  full="$(cf_api_request "$token" GET "/zones/${zone_id}/rulesets/${ruleset_id}")"
  cf_require_success "$full" "ler ruleset de origem" || return 1
  ref="checkuser_dtunnel_$(printf '%s' "$fqdn" | sed 's/[^A-Za-z0-9_]/_/g')"

  body="$(printf '%s' "$full" | jq --arg fqdn "$fqdn" --arg ref "$ref" '
    .result.rules as $rules |
    {
      rules: (
        ($rules // [] | map(select((.ref // "") != $ref and (.description // "") != ("CheckUser DTunnel - " + $fqdn) and (.expression // "") != ("http.host eq \"" + $fqdn + "\""))))
        + [{
          ref: $ref,
          expression: ("http.host eq \"" + $fqdn + "\""),
          description: ("CheckUser DTunnel - " + $fqdn),
          action: "route",
          action_parameters: { origin: { port: 2052 } }
        }]
      )
    }
  ')"

  response="$(cf_api_request "$token" PUT "/zones/${zone_id}/rulesets/${ruleset_id}" "$body")"
  cf_require_success "$response" "criar/atualizar Origin Rule" || return 1
  echo -e "${GREEN}Origin Rule criada/atualizada:${NC} ${fqdn} → porta 2052"
}

configure_cloudflare() {
  require_root
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CLOUDFLARE AUTOMÁTICO${NC}                ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Permissões necessárias no token: Zone Read, DNS Edit e Rulesets/Origin Write."
  echo ""

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}Instalando jq...${NC}"
    apt-get update -y >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null
  fi

  local token zones count choice idx zone_id zone_name sub fqdn ip response cf_url
  token="$(read_cf_token)" || { pause; return; }

  zones="$(cf_api_request "$token" GET "/zones?per_page=100")"
  cf_require_success "$zones" "conectar/listar domínios da Cloudflare" || { pause; return; }
  count="$(printf '%s' "$zones" | jq '.result | length')"
  if [[ "$count" -lt 1 ]]; then
    echo -e "${RED}Nenhum domínio encontrado nessa conta/token.${NC}"
    pause
    return
  fi

  echo -e "${CYAN}Domínios encontrados:${NC}"
  printf '%s' "$zones" | jq -r '.result | to_entries[] | "\(.key + 1). \(.value.name)"'
  echo ""
  read -r -p "Escolha o domínio: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$count" ]]; then
    echo -e "${RED}Opção inválida.${NC}"
    pause
    return
  fi

  idx=$((choice - 1))
  zone_id="$(printf '%s' "$zones" | jq -r ".result[$idx].id")"
  zone_name="$(printf '%s' "$zones" | jq -r ".result[$idx].name")"

  echo ""
  echo "Digite o subdomínio. Exemplos: check, api, vpn"
  echo "Deixe vazio ou use @ para usar o domínio raiz: ${zone_name}"
  read -r -p "Subdomínio: " sub
  fqdn="$(build_cf_hostname "$zone_name" "$sub")" || {
    echo -e "${RED}Subdomínio inválido para a zona ${zone_name}.${NC}"
    pause
    return
  }

  if ! [[ "$fqdn" =~ ^[a-z0-9.-]+$ ]]; then
    echo -e "${RED}Host inválido: ${fqdn}${NC}"
    pause
    return
  fi

  ip="$(get_public_ip)"
  if [[ -z "$ip" ]]; then
    read -r -p "IP público da VPS: " ip
  else
    read -r -p "IP público detectado (${ip}). Pressione ENTER para usar ou digite outro: " response
    [[ -n "$response" ]] && ip="$response"
  fi

  if [[ -z "$ip" ]]; then
    echo -e "${RED}IP público vazio.${NC}"
    pause
    return
  fi

  cf_create_or_update_dns "$token" "$zone_id" "$fqdn" "$ip" || { pause; return; }
  cf_create_or_update_origin_rule "$token" "$zone_id" "$fqdn" || { pause; return; }

  cf_url="https://${fqdn}"
  set_env_key CHECKUSER_CLOUDFLARE_DOMAIN "$fqdn"
  set_env_key CHECKUSER_CLOUDFLARE_URL "$cf_url"
  set_env_key CHECKUSER_PUBLIC_HOST "$fqdn"

  echo ""
  echo -e "${GREEN}✅ Cloudflare configurado com sucesso.${NC}"
  echo "Link do app: ${cf_url}/?user="
  echo "Teste: ${cf_url}/?user=USUARIO"
  echo "UUID:  ${cf_url}/?user=UUID_DO_XRAY"
  echo ""
  echo -e "${YELLOW}Observação:${NC} se usar HTTPS no domínio e o CheckUser estiver em HTTP puro, confira o modo SSL da Cloudflare ou use proxy local/Nginx."
  pause
}

install_status_text() {
  if [[ -x "$BIN_PATH" && -f "$SERVICE_FILE" ]]; then
    echo -e "${GREEN}Instalado${NC}"
  else
    echo -e "${RED}Não instalado${NC}"
  fi
}

service_status_text() {
  if [[ ! -f "$SERVICE_FILE" ]]; then
    echo -e "${YELLOW}Não criado${NC}"
  elif systemctl is-active --quiet checkuser 2>/dev/null; then
    echo -e "${GREEN}Online${NC}"
  else
    echo -e "${RED}Offline${NC}"
  fi
}

show_menu() {
  local installed
  installed="$(install_status_text)"

  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}        ${YELLOW}CHECKUSER DTUNNEL${NC}                    ${CYAN}║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC} Status: ${installed}"
  echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC} ${GREEN}1${NC}. Instalar/Atualizar CheckUser"
  echo -e "${CYAN}║${NC} ${GREEN}2${NC}. Reinstalar CheckUser"
  echo -e "${CYAN}║${NC} ${GREEN}3${NC}. Desinstalar CheckUser"
  echo -e "${CYAN}║${NC} ${GREEN}4${NC}. Limpar DeviceID"
  echo -e "${CYAN}║${NC} ${GREEN}5${NC}. Testar endpoint"
  echo -e "${CYAN}║${NC} ${GREEN}6${NC}. Configurar Cloudflare automático"
  echo -e "${CYAN}║${NC} ${RED}0${NC}. Sair"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
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
      4|04) clear_deviceid ;;
      5|05) test_endpoint ;;
      6|06) configure_cloudflare ;;
      0|00) exit 0 ;;
      *) echo -e "${RED}Opção inválida.${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
