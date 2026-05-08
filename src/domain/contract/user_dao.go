package contract

import (
	"context"

	"github.com/zeusxprime/checkuser/src/domain/entity"
)

type UserDAO interface {
	FindByUsername(ctx context.Context, username string) (*entity.User, error)
}
