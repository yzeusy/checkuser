# CheckUser-Go Primecel / DragonCore

Este pacote é o CheckUser-Go original ajustado por cima do repositório completo enviado, mantendo o endpoint padrão:

```bash
http://127.0.0.1:2052?user=USUARIO
```

Também aceita DeviceID para limite por aparelho:

```bash
http://127.0.0.1:2052?user=USUARIO&deviceid=DEVICE_ID
```

## Ajustes incluídos

- Mantém o link original `http://127.0.0.1:2052`.
- Também mantém compatibilidade com `/check/USUARIO` e `/check?user=USUARIO`.
- Não inventa validade com data atual/+31 dias quando não encontra o usuário.
- Lê validade do Xray/DragonCore por `xrayListUsers`.
- Lê validade e limite do bot em `/etc/tg-access-bot/users.jsonl`.
- Lê revenda/subrevenda em `/etc/tg-access-bot/resellers.json`.
- Bloqueia acesso se a revenda/subrevenda estiver expirada ou bloqueada.
- Suporta consulta por usuário ou UUID do Xray.
- Usa o mesmo limite para SSH e Xray quando o UUID pertence ao mesmo usuário.
- DeviceID fica por usuário, com banco SQLite em `/root/db.sqlite3` por padrão.
- Compatível com Ubuntu 20.04 e 22.04; o instalador baixa Go oficial se o Go do sistema estiver ausente ou antigo.

## Instalação

```bash
sudo bash install.sh
```

Depois teste:

```bash
curl 'http://127.0.0.1:2052?user=USUARIO'
curl 'http://127.0.0.1:2052?user=USUARIO&deviceid=DEVICE_ID'
```

## Comandos

```bash
checkuser-menu
systemctl status checkuser
journalctl -u checkuser -f
```

## Arquivo de configuração

```bash
/etc/checkuser/checkuser.env
```

Variáveis principais:

```env
CHECKUSER_HOST=0.0.0.0
CHECKUSER_PORT=2052
CHECKUSER_DB_PATH=/root/db.sqlite3
CHECKUSER_USUARIOS_DB_PATH=/root/usuarios.db
CHECKUSER_BOT_USERS_LOG=/etc/tg-access-bot/users.jsonl
CHECKUSER_BOT_RESELLERS_JSON=/etc/tg-access-bot/resellers.json
DRAGONCORE_MENU_PATH=/opt/DragonCore/menu.php
DRAGONCORE_PHP_BIN=php
```

## Consulta por UUID do bot

Esta versão mantém o endpoint original na porta 2052 e também aceita o UUID criado pelo bot Telegram.

Consultas aceitas:

```bash
curl "http://127.0.0.1:2052?user=USUARIO"
curl "http://127.0.0.1:2052?user=UUID_DO_XRAY"
curl "http://127.0.0.1:2052?uuid=UUID_DO_XRAY"
curl "http://127.0.0.1:2052/check?user=UUID_DO_XRAY"
curl "http://127.0.0.1:2052/check/UUID_DO_XRAY"
```

Quando recebe um UUID, o CheckUser resolve o usuário real pelo mesmo padrão do bot:

- `/etc/tg-access-bot/users.jsonl`, onde o bot grava `username`, `uuid`, `limit`, `expiry`, `owner_telegram_id`, `owner_name` e `owner_type`;
- DragonCore/Xray, consultando `xrayListUsers` e a tabela `xray` com `nick`, `uuid`, `expiry` e `protocol`.

Depois de resolver o UUID para o usuário/NICK, as mesmas regras são aplicadas:
validade, limite por DeviceID, revenda, subrevenda, bloqueio, suspensão e vencimento.
