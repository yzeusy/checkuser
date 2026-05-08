package user_handler

import (
	"context"
	"errors"

	user_use_case "github.com/zeusxprime/checkuser/src/domain/usecase/user"
	"github.com/zeusxprime/checkuser/src/infra/handler"
)

type checkUserHandler struct {
	checkUserUseCase *user_use_case.CheckUserUseCase
}

func NewCheckUserHandler(checkUserUseCase *user_use_case.CheckUserUseCase) handler.Handler {
	return &checkUserHandler{checkUserUseCase}
}

func (h *checkUserHandler) Handle(ctx context.Context, request *handler.HttpRequest) (*handler.HttpResponse, error) {
	username := firstNonEmpty(
		request.Query("user"),
		request.Query("username"),
		request.Query("usuario"),
		request.Query("uuid"),
		request.Query("xray_uuid"),
		request.Query("id_uuid"),
	)
	deviceID := firstNonEmpty(
		request.Query("deviceId"),
		request.Query("deviceid"),
		request.Query("device_id"),
		request.Query("hwid"),
		request.Query("android_id"),
		request.Query("id"),
	)

	if username == "" {
		return nil, errors.New("informe o usuario: http://127.0.0.1:2052?user=USUARIO ou /check/USUARIO")
	}

	output, err := h.checkUserUseCase.Execute(ctx, username, deviceID)
	if err != nil {
		return nil, err
	}

	return &handler.HttpResponse{
		Status: 200,
		Body:   output,
	}, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
