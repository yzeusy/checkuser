package data

import (
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/zeusxprime/checkuser/src/domain/contract"
)

type bashExecutor struct {
}

func NewBashExecutor() contract.Executor {
	return &bashExecutor{}
}

func commandTimeout() time.Duration {
	raw := strings.TrimSpace(os.Getenv("CHECKUSER_COMMAND_TIMEOUT_SECONDS"))
	if raw == "" {
		return 3 * time.Second
	}
	seconds, err := strconv.Atoi(raw)
	if err != nil || seconds <= 0 {
		return 3 * time.Second
	}
	if seconds > 15 {
		seconds = 15
	}
	return time.Duration(seconds) * time.Second
}

func (b *bashExecutor) Execute(ctx context.Context, command string) (string, error) {
	timeoutCtx, cancel := context.WithTimeout(ctx, commandTimeout())
	defer cancel()

	// Usa shell real para preservar aspas, pipes e redirecionamentos.
	// O split por espaço quebrava comandos como psql -c "SELECT ..." e podia
	// fazer a primeira consulta por UUID falhar ou demorar sem necessidade.
	cmd := exec.CommandContext(timeoutCtx, "bash", "-lc", command)
	result, err := cmd.CombinedOutput()
	if err != nil {
		return strings.TrimSpace(string(result)), err
	}
	return strings.TrimSpace(string(result)), nil
}
