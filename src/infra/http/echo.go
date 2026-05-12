package http

import (
	"crypto/tls"
	"fmt"
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/zeusxprime/checkuser/src/infra/adapter"
	"github.com/zeusxprime/checkuser/src/infra/factory"
	"github.com/zeusxprime/checkuser/src/infra/http/route"
	"golang.org/x/crypto/acme"
)

func Start(host string, port int, sslEnabled bool) {
	e := echo.New()
	e.Use(middleware.CORS())

	checkUserAdapter := adapter.NewEchoAdapter(factory.MakeCheckUserHandler())

	e.GET("/", func(c echo.Context) error {
		// Mantem o link original http://127.0.0.1:2052 como painel do CheckUser.
		// Se receber usuario na raiz, tambem aceita consulta direta:
		// http://127.0.0.1:2052?user=USUARIO
		if c.QueryParam("user") != "" || c.QueryParam("username") != "" || c.QueryParam("usuario") != "" || c.QueryParam("uuid") != "" || c.QueryParam("xray_uuid") != "" || c.QueryParam("id_uuid") != "" {
			return checkUserAdapter.Adapt(c)
		}
		return c.HTML(http.StatusOK, HTML_CONTENT)
	})
	e.POST("/", checkUserAdapter.Adapt)

	e.GET("/device", func(c echo.Context) error {
		return c.HTML(http.StatusOK, DEVICE_HTML_CONTENT)
	})

	api := e.Group("")
	route.CreateUserRoute(api)
	route.CreateDeviceRoute(api)

	addr := fmt.Sprintf("%s:%d", host, port)

	if !sslEnabled {
		e.Logger.Fatal(e.Start(addr))
		return
	}

	certificate, err := tls.X509KeyPair([]byte(CERT_CONTENT), []byte(KEY_CONTENT))
	if err != nil {
		e.Logger.Fatal(err)
		return
	}

	server := http.Server{
		Addr:    addr,
		Handler: e,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{certificate},
			NextProtos:   []string{acme.ALPNProto},
		},
	}

	if err := server.ListenAndServeTLS("", ""); err != http.ErrServerClosed {
		e.Logger.Fatal(err)
	}
}
