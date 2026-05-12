package adapter

import (
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/zeusxprime/checkuser/src/infra/handler"
)

const (
	badRequest    = http.StatusBadRequest
	internalError = http.StatusInternalServerError
)

type EchoAdapter struct {
	handler handler.Handler
}

func NewEchoAdapter(handler handler.Handler) *EchoAdapter {
	return &EchoAdapter{handler: handler}
}

func newResponse(status int, data interface{}) map[string]interface{} {
	return map[string]interface{}{
		"status": status,
		"data":   data,
	}
}

func newErrorResponse(status int, message string) map[string]interface{} {
	return newResponse(status, map[string]string{"error": message})
}

func (ed *EchoAdapter) Adapt(e echo.Context) error {
	query := map[string]interface{}{}
	body := map[string]interface{}{}

	for key, values := range e.QueryParams() {
		if len(values) > 0 {
			query[key] = values[0]
		}
	}

	for _, name := range e.ParamNames() {
		query[name] = e.Param(name)
	}

	// Alguns apps fazem a primeira autenticação via POST/form em vez de GET.
	// O endpoint antigo só olhava querystring, então a primeira tentativa podia
	// cair como usuário vazio e o app ficava preso em connecting.
	if err := e.Request().ParseForm(); err == nil {
		for key, values := range e.Request().PostForm {
			if len(values) > 0 {
				body[key] = values[0]
			}
		}
	}

	if e.Request().ContentLength > 0 && e.Request().Header.Get("Content-Type") != "" {
		jsonBody := map[string]interface{}{}
		if err := e.Bind(&jsonBody); err == nil {
			for key, value := range jsonBody {
				body[key] = value
			}
		}
	}

	httpRequest := handler.NewHttpRequest(query, body)
	response, err := ed.handler.Handle(e.Request().Context(), httpRequest)
	if err != nil {
		return e.JSON(internalError, newErrorResponse(internalError, err.Error()))
	}

	return e.JSON(response.Status, response.Body)
}
