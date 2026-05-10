package user_use_case

import (
	"github.com/zeusxprime/checkuser/src/domain/contract"
	"golang.org/x/net/context"
)

type DetailUserOutput struct {
	ID          int    `json:"id"`
	Username    string `json:"username"`
	ExpiresAt   string `json:"expires_at"`
	ExpiresDays int    `json:"expires_days"`
	ExpiresIn   string `json:"expires_in"`
	Remaining   string `json:"expiration_remaining"`
	Display     string `json:"expiration_display"`
	RemainValue int    `json:"expiration_value"`
	RemainUnit  string `json:"expiration_unit"`
	Limit       int    `json:"limit"`
	Connections int    `json:"connections"`
}

type DetailUserUseCase struct {
	userRepository  contract.UserRepository
	countConnection contract.CountConnection
}

func NewDetailUserUseCase(
	userRepository contract.UserRepository,
	countConnection contract.CountConnection,
) *DetailUserUseCase {
	return &DetailUserUseCase{
		userRepository:  userRepository,
		countConnection: countConnection,
	}
}

func (c *DetailUserUseCase) Execute(ctx context.Context, username string) (*DetailUserOutput, error) {
	user, err := c.userRepository.FindByUsername(ctx, username)
	if err != nil {
		return nil, err
	}

	connections, err := c.countConnection.ByUsername(ctx, user.Username)
	if err != nil {
		connections = 0
	}

	remainingLabel, remainingDays, remainingValue, remainingUnit := expirationRemainingInfo(user.ExpiresAt)

	return &DetailUserOutput{
		ID:          user.ID,
		Username:    user.Username,
		ExpiresAt:   user.ExpiresAt.Format("02/01/2006"),
		Limit:       user.Limit,
		ExpiresDays: remainingDays,
		ExpiresIn:   remainingLabel,
		Remaining:   remainingLabel,
		Display:     remainingLabel,
		RemainValue: remainingValue,
		RemainUnit:  remainingUnit,
		Connections: connections,
	}, nil
}
