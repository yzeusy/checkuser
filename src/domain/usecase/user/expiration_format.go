package user_use_case

import (
	"fmt"
	"time"
)

func expirationRemainingInfo(expiresAt time.Time) (string, int, int, string) {
	remaining := time.Until(expiresAt)
	if remaining <= 0 {
		return "expirado", 0, 0, "expired"
	}

	// Arredonda para baixo: no último minuto mostra 00h:00,
	// mas a conta só expira quando remaining <= 0.
	totalMinutes := int(remaining.Minutes())

	// Menos de 24h: mostra somente hora:minuto, como se fosse 0 dias.
	// Mantém expiration_unit como "days" para compatibilidade com apps/checkers
	// que só tratam a unidade days, mas o texto exibido fica 23h:59.
	if totalMinutes < 1440 {
		hours := totalMinutes / 60
		minutes := totalMinutes % 60
		return fmt.Sprintf("%02dh:%02d", hours, minutes), 0, 0, "days"
	}

	// Acima de 24h: mostra em dias, sem acumular como 29h:59.
	days := totalMinutes / 1440
	if days <= 1 {
		return "1 dia", 1, 1, "days"
	}

	return fmt.Sprintf("%d dias", days), days, days, "days"
}
