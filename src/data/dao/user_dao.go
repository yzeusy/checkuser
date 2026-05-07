package dao

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/yzeusy/checkuser/src/domain/contract"
	"github.com/yzeusy/checkuser/src/domain/entity"
)

type userDAO struct {
	executor contract.Executor
}

type xrayIdentity struct {
	Nick   string
	UUID   string
	Expiry string
}

func NewUserDAO(executor contract.Executor) contract.UserDAO {
	return &userDAO{executor: executor}
}

func (u *userDAO) FindByUsername(ctx context.Context, username string) (*entity.User, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		return nil, fmt.Errorf("usuario vazio")
	}
	if !isSafeLookupValue(username) {
		return nil, fmt.Errorf("usuario invalido")
	}

	canonical := u.canonicalUsername(ctx, username)
	lookup := u.lookupNames(ctx, username)
	if canonical != "" {
		lookup[normalizeKey(canonical)] = true
	}

	if suspended, reason := u.accessSuspendedByResellerLookup(lookup); suspended {
		return nil, fmt.Errorf("acesso suspenso: %s", reason)
	}

	expiresAt, err := u.getExpirationDateByLookup(ctx, username, lookup)
	if err != nil || expiresAt.IsZero() {
		return nil, fmt.Errorf("validade nao encontrada para o usuario %s", username)
	}
	if time.Now().After(expiresAt) {
		return nil, fmt.Errorf("acesso expirado para o usuario %s", username)
	}

	id, err := u.getUserIDByLookup(lookup)
	if err != nil {
		id = -1
	}

	limit := u.getConnectionLimitByLookup(ctx, lookup)
	if limit <= 0 {
		limit = 1
	}

	if canonical == "" {
		canonical = username
	}

	return &entity.User{
		ID:        id,
		Username:  canonical,
		ExpiresAt: expiresAt,
		Limit:     limit,
	}, nil
}

func (u *userDAO) canonicalUsername(ctx context.Context, username string) string {
	wanted := normalizeKey(username)
	for _, item := range u.listDragonCoreXrayUsers(ctx) {
		nick := strings.TrimSpace(item.Nick)
		uuid := strings.TrimSpace(item.UUID)
		if normalizeKey(nick) == wanted || normalizeKey(uuid) == wanted {
			if nick != "" {
				return nick
			}
		}
	}
	for _, row := range readBotLogRows() {
		rowUsername := strings.TrimSpace(stringFromAny(row["username"]))
		rowUUID := strings.TrimSpace(stringFromAny(row["uuid"]))
		if normalizeKey(rowUsername) == wanted || normalizeKey(rowUUID) == wanted {
			if rowUsername != "" {
				return rowUsername
			}
		}
	}
	return username
}

func (u *userDAO) getConnectionLimitByLookup(ctx context.Context, lookup map[string]bool) int {
	// 1. Base comum gravada pelo bot e por gestores:
	//    /root/usuarios.db
	//    formatos aceitos:
	//    usuario senha limite validade
	//    usuario senha uuid validade limite
	//    usuario|senha|uuid|validade|limite
	//    usuario limit=2 expiry=2026-06-05
	if limit, ok := getLimitFromUsuariosDB(lookup); ok && limit > 0 {
		return limit
	}

	// 2. Log persistente do bot Telegram:
	//    /etc/tg-access-bot/users.jsonl
	//    campos comuns: username, uuid, limit, expiry, expires_at.
	if limit, ok := getLimitFromBotLog(lookup); ok && limit > 0 {
		return limit
	}

	// 3. DragonCore/gestores antigos.
	for _, candidate := range orderedLookupValues(lookup) {
		if limit, ok := u.getConnectionLimitFromDragonCoreCommands(ctx, candidate); ok && limit > 0 {
			return limit
		}
	}

	return 1
}

func (u *userDAO) getConnectionLimit(ctx context.Context, username string) int {
	return u.getConnectionLimitByLookup(ctx, u.lookupNames(ctx, username))
}

func (u *userDAO) getConnectionLimitFromDragonCoreCommands(ctx context.Context, username string) (int, bool) {
	connLimitPattern := regexp.MustCompile(`(?i)connection[_ -]?limit\s*[:=]\s*(\d+)`)
	phpLimitPattern := regexp.MustCompile(`\|\s*(\d+)(?:\s*\||\s*$)`)

	vpsOut, _ := u.executeCommand(ctx, fmt.Sprintf("vps view -u %s", shellQuote(username)))
	if matches := connLimitPattern.FindStringSubmatch(vpsOut); len(matches) > 1 {
		if n, err := strconv.Atoi(matches[1]); err == nil {
			return n, true
		}
	}

	phpOut, _ := u.executeCommand(ctx, fmt.Sprintf("php /opt/DragonCore/menu.php printlim2 %s", shellQuote(username)))
	if matches := phpLimitPattern.FindStringSubmatch(phpOut); len(matches) > 1 {
		if n, err := strconv.Atoi(matches[1]); err == nil {
			return n, true
		}
	}

	return 0, false
}

func (u *userDAO) accessSuspendedByReseller(ctx context.Context, username string) (bool, string) {
	return u.accessSuspendedByResellerLookup(u.lookupNames(ctx, username))
}

func (u *userDAO) accessSuspendedByResellerLookup(lookup map[string]bool) (bool, string) {
	rows := readBotLogRows()
	for i := len(rows) - 1; i >= 0; i-- {
		row := rows[i]
		if !rowMatchesLookup(row, lookup) {
			continue
		}

		ownerType := normalizeKey(stringFromAny(row["owner_type"]))
		if ownerType == "" || ownerType == "admin" {
			return false, ""
		}

		ownerID, ok := int64FromAny(row["owner_telegram_id"])
		if !ok || ownerID <= 0 {
			ownerID, ok = int64FromAny(row["reseller_telegram_id"])
		}
		if !ok || ownerID <= 0 {
			return false, ""
		}

		return resellerChainSuspended(ownerID)
	}
	return false, ""
}

func resellerChainSuspended(ownerID int64) (bool, string) {
	rows := readBotResellerRows()
	if len(rows) == 0 {
		return false, ""
	}

	currentID := ownerID
	seen := map[int64]bool{}
	first := true

	for currentID > 0 {
		if seen[currentID] {
			return true, "cadeia de revenda invalida"
		}
		seen[currentID] = true

		row, ok := rows[currentID]
		if !ok {
			return false, ""
		}

		label := "revenda"
		if !first {
			label = "revenda principal"
		}

		if active, ok := boolFromAny(row["active"]); ok && !active {
			return true, label + " bloqueada"
		}
		if blocked, ok := boolFromAny(row["blocked"]); ok && blocked {
			return true, label + " bloqueada"
		}

		expiresAt := stringFromAny(row["expires_at"])
		if expiresAt == "" {
			expiresAt = stringFromAny(row["expiry"])
		}
		if expiresAt == "" {
			expiresAt = stringFromAny(row["expires"])
		}
		if expiry, ok := parseDateToEndOfDay(expiresAt); ok && time.Now().After(expiry) {
			return true, label + " expirada"
		}

		parentID, ok := int64FromAny(row["parent_telegram_id"])
		if !ok || parentID <= 0 {
			parentID, ok = int64FromAny(row["parent_id"])
		}
		if !ok || parentID <= 0 {
			return false, ""
		}
		currentID = parentID
		first = false
	}

	return false, ""
}

func readBotResellerRows() map[int64]map[string]any {
	path := botResellersPath()
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}

	rows := make(map[int64]map[string]any)

	// Formato principal: objeto indexado por Telegram ID.
	var byKey map[string]map[string]any
	if err := json.Unmarshal(data, &byKey); err == nil && len(byKey) > 0 {
		for key, row := range byKey {
			id, ok := int64FromAny(row["telegram_id"])
			if !ok || id <= 0 {
				if parsed, err := strconv.ParseInt(strings.TrimSpace(key), 10, 64); err == nil && parsed > 0 {
					id = parsed
				} else {
					continue
				}
			}
			rows[id] = row
		}
		return rows
	}

	// Formato alternativo: lista de objetos.
	var list []map[string]any
	if err := json.Unmarshal(data, &list); err == nil {
		for _, row := range list {
			id, ok := int64FromAny(row["telegram_id"])
			if ok && id > 0 {
				rows[id] = row
			}
		}
	}

	return rows
}

func (u *userDAO) getExpirationDate(ctx context.Context, username string) (time.Time, error) {
	return u.getExpirationDateByLookup(ctx, username, u.lookupNames(ctx, username))
}

func (u *userDAO) getExpirationDateByLookup(ctx context.Context, username string, lookup map[string]bool) (time.Time, error) {
	// 1. DragonCore Xray: validade real em xray.expiry, exposta pelo menu.
	if expirationDate, ok := u.getDragonCoreXrayExpirationDate(ctx, lookup); ok {
		return expirationDate, nil
	}

	// 2. Bot Telegram.
	if expirationDate, ok := u.getBotAccessExpirationDate(lookup); ok {
		return expirationDate, nil
	}

	// 3. Base compartilhada.
	if expirationDate, ok := u.getUsuariosDBExpirationDate(lookup); ok {
		return expirationDate, nil
	}

	// 4. SSH/Linux.
	for _, candidate := range orderedLookupValues(lookup) {
		if expirationDate, err := u.getLinuxExpirationDate(ctx, candidate); err == nil {
			return expirationDate, nil
		}
	}

	return time.Time{}, fmt.Errorf("validade nao encontrada para %s", username)
}

func (u *userDAO) getDragonCoreXrayExpirationDate(ctx context.Context, lookup map[string]bool) (time.Time, bool) {
	for _, item := range u.listDragonCoreXrayUsers(ctx) {
		if !lookup[normalizeKey(item.Nick)] && !lookup[normalizeKey(item.UUID)] {
			continue
		}
		if expirationDate, ok := parseDateToEndOfDay(item.Expiry); ok {
			return expirationDate, true
		}
	}
	return time.Time{}, false
}

func (u *userDAO) listDragonCoreXrayUsers(ctx context.Context) []xrayIdentity {
	outputs := []string{}

	if output, err := u.executeCommand(ctx, fmt.Sprintf("%s %s xrayListUsers", shellQuote(phpBin()), shellQuote(dragonCoreMenuPath()))); err == nil && strings.TrimSpace(output) != "" {
		outputs = append(outputs, output)
	}

	// Fallback direto no PostgreSQL, caso o menu não exista ou mude o formato.
	psqlCmd := `psql -U dragoncore -d dragoncore -t -A -F '|' -c "SELECT nick, uuid, expiry FROM xray" 2>/dev/null`
	if output, err := u.executeCommand(ctx, psqlCmd); err == nil && strings.TrimSpace(output) != "" {
		outputs = append(outputs, output)
	}

	items := make([]xrayIdentity, 0)
	linePattern := regexp.MustCompile(`(?i)ID:\s*\d+\s*\|\s*NICK:\s*([^|]+)\s*\|\s*UUID:\s*([^|]+)\s*\|\s*EXPIRA:\s*([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}/[0-9]{2}/[0-9]{4})`)
	for _, output := range outputs {
		for _, line := range strings.Split(output, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}

			if matches := linePattern.FindStringSubmatch(line); len(matches) >= 4 {
				items = append(items, xrayIdentity{Nick: strings.TrimSpace(matches[1]), UUID: strings.TrimSpace(matches[2]), Expiry: strings.TrimSpace(matches[3])})
				continue
			}

			// Fallback psql: nick|uuid|expiry
			parts := strings.Split(line, "|")
			if len(parts) >= 3 {
				items = append(items, xrayIdentity{Nick: strings.TrimSpace(parts[0]), UUID: strings.TrimSpace(parts[1]), Expiry: strings.TrimSpace(parts[2])})
			}
		}
	}
	return items
}

func (u *userDAO) getBotAccessExpirationDate(lookup map[string]bool) (time.Time, bool) {
	var last time.Time
	ok := false
	for _, row := range readBotLogRows() {
		if !rowMatchesLookup(row, lookup) {
			continue
		}
		expiry := stringFromAny(row["expiry"])
		if expiry == "" {
			expiry = stringFromAny(row["expires_at"])
		}
		if expiry == "" {
			expiry = stringFromAny(row["validade"])
		}
		if t, parsed := parseDateToEndOfDay(expiry); parsed {
			last = t
			ok = true
		}
	}
	return last, ok
}

func (u *userDAO) getUsuariosDBExpirationDate(lookup map[string]bool) (time.Time, bool) {
	lines := readLines(usuariosDBPath())
	var last time.Time
	ok := false
	for _, line := range lines {
		fields := splitRecordFields(line)
		if len(fields) < 2 || !lookup[normalizeKey(fields[0])] {
			continue
		}
		for i := len(fields) - 1; i >= 1; i-- {
			if t, parsed := parseDateToEndOfDay(fields[i]); parsed {
				last = t
				ok = true
				break
			}
		}
	}
	return last, ok
}

func (u *userDAO) getLinuxExpirationDate(ctx context.Context, username string) (time.Time, error) {
	command := fmt.Sprintf("chage -l %s", shellQuote(username))
	output, err := u.executor.Execute(ctx, command)
	if err != nil {
		return time.Time{}, err
	}

	search := regexp.MustCompile(`(?im)^(Account expires|Conta expira|Conta expira em|Expira)\s*:\s*(.*)$`).FindStringSubmatch(output)
	if len(search) < 3 {
		return time.Time{}, fmt.Errorf("validade linux nao encontrada para %s", username)
	}

	value := strings.TrimSpace(search[2])
	if value == "" {
		return time.Time{}, fmt.Errorf("validade linux vazia para %s", username)
	}

	if strings.EqualFold(value, "never") || strings.EqualFold(value, "nunca") || strings.EqualFold(value, "jamais") {
		return time.Date(2099, 12, 31, 23, 59, 59, 0, time.Local), nil
	}

	if expirationDate, ok := parseDateToEndOfDay(value); ok {
		return expirationDate, nil
	}

	return time.Time{}, fmt.Errorf("formato de validade linux invalido para %s: %s", username, value)
}

func (u *userDAO) lookupNames(ctx context.Context, username string) map[string]bool {
	lookup := map[string]bool{normalizeKey(username): true}
	wanted := normalizeKey(username)

	for _, item := range u.listDragonCoreXrayUsers(ctx) {
		nick := normalizeKey(item.Nick)
		uuid := normalizeKey(item.UUID)
		if nick == wanted || uuid == wanted {
			if nick != "" {
				lookup[nick] = true
			}
			if uuid != "" {
				lookup[uuid] = true
			}
		}
	}

	for _, row := range readBotLogRows() {
		rowUsername := normalizeKey(stringFromAny(row["username"]))
		rowUUID := normalizeKey(stringFromAny(row["uuid"]))
		if rowUsername == wanted || rowUUID == wanted {
			if rowUsername != "" {
				lookup[rowUsername] = true
			}
			if rowUUID != "" {
				lookup[rowUUID] = true
			}
		}
	}

	return lookup
}

func getLimitFromUsuariosDB(lookup map[string]bool) (int, bool) {
	lines := readLines(usuariosDBPath())
	var last int
	ok := false

	for _, line := range lines {
		fields := splitRecordFields(line)
		if len(fields) < 2 || !lookup[normalizeKey(fields[0])] {
			continue
		}

		// Formato bot atual: usuario senha limite validade
		if len(fields) >= 4 {
			if n, parsed := positiveInt(fields[2]); parsed {
				last = n
				ok = true
				continue
			}
		}

		// Formato completo: usuario senha uuid validade limite
		if len(fields) >= 5 {
			if n, parsed := positiveInt(fields[4]); parsed {
				last = n
				ok = true
				continue
			}
		}

		// Formato antigo: usuario limite validade
		if len(fields) >= 3 {
			if n, parsed := positiveInt(fields[1]); parsed {
				last = n
				ok = true
				continue
			}
		}

		if n, parsed := extractNamedLimit(line); parsed {
			last = n
			ok = true
		}
	}

	return last, ok
}

func getLimitFromBotLog(lookup map[string]bool) (int, bool) {
	var last int
	ok := false
	for _, row := range readBotLogRows() {
		if !rowMatchesLookup(row, lookup) {
			continue
		}
		if n, parsed := intFromAny(row["limit"]); parsed && n > 0 {
			last = n
			ok = true
		}
		if n, parsed := intFromAny(row["limite"]); parsed && n > 0 {
			last = n
			ok = true
		}
	}
	return last, ok
}

func rowMatchesLookup(row map[string]any, lookup map[string]bool) bool {
	values := []string{
		stringFromAny(row["username"]),
		stringFromAny(row["user"]),
		stringFromAny(row["uuid"]),
		stringFromAny(row["user_uuid"]),
		stringFromAny(row["nick"]),
	}
	for _, value := range values {
		if lookup[normalizeKey(value)] {
			return true
		}
	}
	return false
}

func readBotLogRows() []map[string]any {
	path := botUsersLogPath()
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	rows := make([]map[string]any, 0)
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return rows
	}

	// JSONL principal.
	for _, line := range strings.Split(trimmed, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.HasPrefix(line, "{") {
			continue
		}
		var row map[string]any
		if err := json.Unmarshal([]byte(line), &row); err == nil {
			rows = append(rows, row)
		}
	}
	if len(rows) > 0 {
		return rows
	}

	// Fallback: arquivo JSON completo.
	var list []map[string]any
	if err := json.Unmarshal(data, &list); err == nil {
		return list
	}
	var obj map[string]map[string]any
	if err := json.Unmarshal(data, &obj); err == nil {
		for _, row := range obj {
			rows = append(rows, row)
		}
	}
	return rows
}

func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	lines := make([]string, 0)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			lines = append(lines, line)
		}
	}
	return lines
}

func splitRecordFields(line string) []string {
	replacer := strings.NewReplacer("|", " ", ";", " ", ",", " ", "\t", " ")
	return strings.Fields(replacer.Replace(line))
}

func extractNamedLimit(line string) (int, bool) {
	patterns := []string{
		`(?i)(?:limit|limite|connection_limit|connection-limit)\s*[:=]\s*(\d+)`,
		`(?i)(?:limit|limite|connection_limit|connection-limit)\s+(\d+)`,
	}
	for _, pattern := range patterns {
		matches := regexp.MustCompile(pattern).FindStringSubmatch(line)
		if len(matches) > 1 {
			if n, ok := positiveInt(matches[1]); ok {
				return n, true
			}
		}
	}
	return 0, false
}

func positiveInt(value string) (int, bool) {
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

func intFromAny(value any) (int, bool) {
	switch v := value.(type) {
	case int:
		return v, v > 0
	case int64:
		return int(v), v > 0
	case float64:
		n := int(v)
		return n, n > 0
	case string:
		return positiveInt(v)
	default:
		return 0, false
	}
}

func int64FromAny(value any) (int64, bool) {
	switch v := value.(type) {
	case int:
		return int64(v), v > 0
	case int64:
		return v, v > 0
	case float64:
		n := int64(v)
		return n, n > 0
	case string:
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		return n, err == nil && n > 0
	default:
		return 0, false
	}
}

func boolFromAny(value any) (bool, bool) {
	switch v := value.(type) {
	case bool:
		return v, true
	case string:
		s := normalizeKey(v)
		if s == "1" || s == "true" || s == "yes" || s == "sim" || s == "on" || s == "ativo" || s == "active" {
			return true, true
		}
		if s == "0" || s == "false" || s == "no" || s == "nao" || s == "não" || s == "off" || s == "bloqueado" || s == "blocked" {
			return false, true
		}
	}
	return false, false
}

func stringFromAny(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case fmt.Stringer:
		return strings.TrimSpace(v.String())
	case nil:
		return ""
	default:
		return strings.TrimSpace(fmt.Sprint(v))
	}
}

func parseDateToEndOfDay(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "suspenso") || strings.EqualFold(value, "suspended") {
		return time.Time{}, false
	}
	layouts := []string{
		"2006-01-02",
		"02/01/2006",
		"02-01-2006",
		"Jan 02, 2006",
		"Jan 2, 2006",
		"2006/01/02",
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05Z07:00",
	}
	for _, layout := range layouts {
		if parsed, err := time.ParseInLocation(layout, value, time.Local); err == nil {
			return endOfDay(parsed), true
		}
	}
	return time.Time{}, false
}

func endOfDay(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 23, 59, 59, 0, time.Local)
}

func (u *userDAO) getUserID(username string) (int, error) {
	return u.getUserIDByLookup(u.lookupNames(context.Background(), username))
}

func (u *userDAO) getUserIDByLookup(lookup map[string]bool) (int, error) {
	data, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return -1, err
	}

	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.Split(line, ":")
		if len(parts) < 3 {
			continue
		}
		if !lookup[normalizeKey(parts[0])] {
			continue
		}
		return strconv.Atoi(parts[2])
	}

	return -1, nil
}

func (u *userDAO) executeCommand(ctx context.Context, command string) (string, error) {
	output, err := u.executor.Execute(ctx, command)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(output), nil
}

func usuariosDBPath() string {
	if path := strings.TrimSpace(os.Getenv("CHECKUSER_USUARIOS_DB_PATH")); path != "" {
		return path
	}
	if path := strings.TrimSpace(os.Getenv("USUARIOS_DB_PATH")); path != "" {
		return path
	}
	return "/root/usuarios.db"
}

func botUsersLogPath() string {
	if path := strings.TrimSpace(os.Getenv("CHECKUSER_BOT_USERS_LOG")); path != "" {
		return path
	}
	if dir := strings.TrimSpace(os.Getenv("BOT_DATA_DIR")); dir != "" {
		return strings.TrimRight(dir, "/") + "/users.jsonl"
	}
	return "/etc/tg-access-bot/users.jsonl"
}

func botResellersPath() string {
	if path := strings.TrimSpace(os.Getenv("CHECKUSER_BOT_RESELLERS_JSON")); path != "" {
		return path
	}
	if dir := strings.TrimSpace(os.Getenv("BOT_DATA_DIR")); dir != "" {
		return strings.TrimRight(dir, "/") + "/resellers.json"
	}
	return "/etc/tg-access-bot/resellers.json"
}

func dragonCoreMenuPath() string {
	if path := strings.TrimSpace(os.Getenv("DRAGONCORE_MENU_PATH")); path != "" {
		return path
	}
	return "/opt/DragonCore/menu.php"
}

func phpBin() string {
	if path := strings.TrimSpace(os.Getenv("DRAGONCORE_PHP_BIN")); path != "" {
		return path
	}
	return "php"
}

func normalizeKey(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func orderedLookupValues(lookup map[string]bool) []string {
	values := make([]string, 0, len(lookup))
	for value := range lookup {
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}

func isSafeLookupValue(value string) bool {
	return regexp.MustCompile(`^[A-Za-z0-9_.@:-]{1,128}$`).MatchString(value)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
