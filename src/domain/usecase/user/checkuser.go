package user_use_case

import (
	"context"

	"github.com/zeusxprime/checkuser/src/domain/contract"
	"github.com/zeusxprime/checkuser/src/domain/entity"
)

type CheckUserOutput struct {
	ID          int    `json:"id"`
	Username    string `json:"username"`
	ExpiresAt   string `json:"expiration_date"`
	ExpiresDays int    `json:"expiration_days"`
	ExpiresIn   string `json:"expires_in"`
	Remaining   string `json:"expiration_remaining"`
	Display     string `json:"expiration_display"`
	RemainValue int    `json:"expiration_value"`
	RemainUnit  string `json:"expiration_unit"`
	Limit       int    `json:"limit_connections"`
	Connections int    `json:"count_connections"`
}

type CheckUserUseCase struct {
	userRepository   contract.UserRepository
	deviceRepository contract.DeviceRepository
}

func NewCheckUserUseCase(
	userRepository contract.UserRepository,
	deviceRepository contract.DeviceRepository,
) *CheckUserUseCase {
	return &CheckUserUseCase{
		userRepository:   userRepository,
		deviceRepository: deviceRepository,
	}
}

func (c *CheckUserUseCase) Execute(ctx context.Context, username, deviceID string) (*CheckUserOutput, error) {
	user, err := c.userRepository.FindByUsername(ctx, username)
	if err != nil {
		return nil, err
	}

	existingDevices, err := c.deviceRepository.CountByUsername(ctx, user.Username)
	if err != nil {
		return nil, err
	}

	// Mantém compatibilidade com o endpoint padrão:
	//   /check?user=USUARIO
	// Quando o app enviar deviceId/deviceid, o limite por aparelho é aplicado.
	if deviceID != "" {
		device := &entity.Device{
			ID:       deviceID,
			Username: user.Username,
		}

		deviceExists := c.deviceRepository.Exists(ctx, device)
		limitReached := !deviceExists && user.LimitReached(existingDevices)

		if !deviceExists && !limitReached {
			if err := c.deviceRepository.Save(ctx, device); err != nil {
				return nil, err
			}
			existingDevices++
		}

		if limitReached {
			existingDevices = user.Limit + 1
		}
	}

	remainingLabel, remainingDays, remainingValue, remainingUnit := expirationRemainingInfo(user.ExpiresAt)

	return &CheckUserOutput{
		ID:          user.ID,
		Username:    user.Username,
		ExpiresAt:   user.ExpiresAt.Format("02/01/2006"),
		ExpiresDays: remainingDays,
		ExpiresIn:   remainingLabel,
		Remaining:   remainingLabel,
		Display:     remainingLabel,
		RemainValue: remainingValue,
		RemainUnit:  remainingUnit,
		Limit:       user.Limit,
		Connections: existingDevices,
	}, nil
}
