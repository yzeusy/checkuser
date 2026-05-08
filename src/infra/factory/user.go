package factory

import (
	"github.com/zeusxprime/checkuser/src/data"
	"github.com/zeusxprime/checkuser/src/data/cache"
	"github.com/zeusxprime/checkuser/src/data/connection"
	"github.com/zeusxprime/checkuser/src/data/dao"
	"github.com/zeusxprime/checkuser/src/data/repository"
	user_use_case "github.com/zeusxprime/checkuser/src/domain/usecase/user"
	"github.com/zeusxprime/checkuser/src/infra/handler"
	user_handler "github.com/zeusxprime/checkuser/src/infra/handler/user"
)

func MakeCheckUserHandler() handler.Handler {
	executor := data.NewBashExecutor()
	userDAO := dao.NewUserDAO(executor)
	userRepository := repository.NewSystemUserRepository(userDAO)
	deviceRepository := repository.NewSQLiteDeviceRepository()
	checkUserUseCase := user_use_case.NewCheckUserUseCase(userRepository, deviceRepository)
	return user_handler.NewCheckUserHandler(checkUserUseCase)
}

func MakeCountConnectionsHandler() handler.Handler {
	executor := data.NewBashExecutor()
	countSSH := connection.NewSSHConnection(executor)
	countSSH.SetNext(connection.NewOpenVPNConnection(connection.NewAUXOpenVPNConnection("127.0.0.1", 7505)))
	countConnectionCacheService := cache.NewCountConnectionCacheService()
	countConnectionsUseCase := user_use_case.NewCountConnectionsUseCase(countSSH, countConnectionCacheService)
	return user_handler.NewCountConnectionsHandler(countConnectionsUseCase)
}

func MakeDetailsUserHandler() handler.Handler {
	executor := data.NewBashExecutor()
	userDAO := dao.NewUserDAO(executor)
	userRepository := repository.NewSystemUserRepository(userDAO)
	countSSH := connection.NewSSHConnection(executor)
	countSSH.SetNext(connection.NewOpenVPNConnection(connection.NewAUXOpenVPNConnection("127.0.0.1", 7505)))
	checkUserUseCase := user_use_case.NewDetailUserUseCase(userRepository, countSSH)
	return user_handler.NewDetailUserHandler(checkUserUseCase)
}
