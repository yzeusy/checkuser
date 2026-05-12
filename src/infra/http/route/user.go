package route

import (
	"github.com/labstack/echo/v4"
	"github.com/zeusxprime/checkuser/src/infra/adapter"
	"github.com/zeusxprime/checkuser/src/infra/factory"
)

func CreateUserRoute(g *echo.Group) {
	// Mantem compatibilidade com rotas de consulta.
	// Base original: http://127.0.0.1:2052
	// Consulta tambem aceita: /check?user=USUARIO e /check/USUARIO
	checkAdapter := adapter.NewEchoAdapter(factory.MakeCheckUserHandler())
	g.GET("/check", checkAdapter.Adapt)
	g.POST("/check", checkAdapter.Adapt)

	// Compatibilidade com rotas antigas do projeto original.
	g.GET("/check/:username", checkAdapter.Adapt)
	g.POST("/check/:username", checkAdapter.Adapt)
	g.GET("/details/:username", adapter.NewEchoAdapter(factory.MakeDetailsUserHandler()).Adapt)
	g.GET("/count", adapter.NewEchoAdapter(factory.MakeCountConnectionsHandler()).Adapt)
}
