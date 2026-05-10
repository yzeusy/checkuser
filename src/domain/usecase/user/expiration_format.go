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

	totalMinutes := int(remaining.Minutes())
	if totalMinutes < 1 {
		totalMinutes = 1
	}

	// Menos de 24h: mostra hora:minuto, sem ficar como 0 dias.
	if totalMinutes < 1440 {
		hours := totalMinutes / 60
		minutes := totalMinutes % 60
		return fmt.Sprintf("%02dh:%02d", hours, minutes), 0, totalMinutes, "minutes"
	}

	// Acima de 24h: calcula em tempo real e arredonda para baixo.
	// Ex.: 29 dias e algumas horas = 29 dias, não fica preso em 30.
	days := totalMinutes / 1440
	if days <= 1 {
		return "1 dia", 1, 1, "days"
	}

	return fmt.Sprintf("%d dias", days), days, days, "days"
}
