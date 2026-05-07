package route

import (
	"github.com/DTunnel0/CheckUser-Go/src/infra/adapter"
	"github.com/DTunnel0/CheckUser-Go/src/infra/factory"
	"github.com/labstack/echo/v4"
)

func CreateUserRoute(g *echo.Group) {
	// Mantem compatibilidade com rotas de consulta.
	// Base original: http://127.0.0.1:2052
	// Consulta tambem aceita: /check?user=USUARIO e /check/USUARIO
	g.GET("/check", adapter.NewEchoAdapter(factory.MakeCheckUserHandler()).Adapt)

	// Compatibilidade com rotas antigas do projeto original.
	g.GET("/check/:username", adapter.NewEchoAdapter(factory.MakeCheckUserHandler()).Adapt)
	g.GET("/details/:username", adapter.NewEchoAdapter(factory.MakeDetailsUserHandler()).Adapt)
	g.GET("/count", adapter.NewEchoAdapter(factory.MakeCountConnectionsHandler()).Adapt)
}
