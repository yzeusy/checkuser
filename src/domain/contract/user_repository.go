package contract

import (
	"context"

	"github.com/zeusxprime/checkuser/src/domain/entity"
)

type UserRepository interface {
	FindByUsername(ctx context.Context, username string) (*entity.User, error)
}
