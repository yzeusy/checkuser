package user_use_case

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/zeusxprime/checkuser/src/domain/contract"
	"github.com/zeusxprime/checkuser/src/domain/entity"
)

type CheckUserOutput struct {
	ID            int    `json:"id"`
	Username      string `json:"username"`
	ExpiresAt     string `json:"expiration_date"`
	ExpiresDays   int    `json:"expiration_days"`
	ExpiresIn     string `json:"expires_in"`
	Remaining     string `json:"expiration_remaining"`
	Display       string `json:"expiration_display"`
	RemainValue   int    `json:"expiration_value"`
	RemainUnit    string `json:"expiration_unit"`
	Limit         int    `json:"limit_connections"`
	Connections   int    `json:"count_connections"`
	DeviceCount   int    `json:"device_count"`
	DeviceLimit   int    `json:"device_limit"`
	DeviceAllowed bool   `json:"device_allowed"`
	DeviceStatus  string `json:"device_status"`
	DeviceUUID    string `json:"device_uuid"`
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

	deviceAllowed := true
	deviceStatus := "ok"
	deviceID = strings.TrimSpace(deviceID)

	// Compatibilidade:
	//   /check?user=USUARIO continua funcionando sem deviceid.
	// Proteção por aparelho:
	//   /check?user=USUARIO&deviceid=DEVICE registra por usuario e respeita o limite.
	// MultiVPS:
	//   se CHECKUSER_DEVICE_MASTER_URL estiver configurado no secundario,
	//   a validacao do deviceid consulta/grava primeiro na principal para o cliente
	//   nao conseguir burlar o limite usando outra VPS.
	if deviceID != "" {
		device := &entity.Device{
			ID:       deviceID,
			Username: user.Username,
			Limit:    user.Limit,
		}

		deviceExists := c.deviceRepository.Exists(ctx, device)

		if masterURL := strings.TrimSpace(os.Getenv("CHECKUSER_DEVICE_MASTER_URL")); masterURL != "" && !isMasterBypass() {
			remoteCount, remoteLimit, remoteAllowed, remoteOK := c.checkDeviceOnMaster(ctx, masterURL, user.Username, deviceID)
			if remoteOK {
				if remoteLimit > 0 {
					user.Limit = remoteLimit
					device.Limit = remoteLimit
				}
				existingDevices = remoteCount
				deviceAllowed = remoteAllowed
				if !remoteAllowed {
					deviceStatus = "limit_reached"
				} else {
					deviceStatus = "ok_master"
					_ = c.deviceRepository.Save(ctx, device)
				}
			} else if !deviceExists {
				// Modo seguro: se o secundario nao conseguiu validar na principal,
				// nao libera um aparelho novo localmente.
				deviceAllowed = false
				deviceStatus = "master_unavailable"
				existingDevices = user.Limit + 1
			}
		} else {
			limitReached := !deviceExists && user.LimitReached(existingDevices)

			if !deviceExists && !limitReached {
				if err := c.deviceRepository.Save(ctx, device); err != nil {
					return nil, err
				}
				existingDevices++
			}

			if limitReached {
				deviceAllowed = false
				deviceStatus = "limit_reached"
				existingDevices = user.Limit + 1
			}
		}
	}

	remainingLabel, remainingDays, remainingValue, remainingUnit := expirationRemainingInfo(user.ExpiresAt)

	return &CheckUserOutput{
		ID:            user.ID,
		Username:      user.Username,
		ExpiresAt:     user.ExpiresAt.Format("02/01/2006"),
		ExpiresDays:   remainingDays,
		ExpiresIn:     remainingLabel,
		Remaining:     remainingLabel,
		Display:       remainingLabel,
		RemainValue:   remainingValue,
		RemainUnit:    remainingUnit,
		Limit:         user.Limit,
		Connections:   existingDevices,
		DeviceCount:   existingDevices,
		DeviceLimit:   user.Limit,
		DeviceAllowed: deviceAllowed,
		DeviceStatus:  deviceStatus,
		DeviceUUID:    "",
	}, nil
}

func isMasterBypass() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("CHECKUSER_DEVICE_MASTER_BYPASS")))
	return v == "1" || v == "true" || v == "yes" || v == "sim"
}

func (c *CheckUserUseCase) checkDeviceOnMaster(ctx context.Context, masterURL, username, deviceID string) (int, int, bool, bool) {
	u, err := url.Parse(masterURL)
	if err != nil {
		return 0, 0, false, false
	}
	if u.Scheme == "" {
		u.Scheme = "http"
	}
	if u.Path == "" || u.Path == "/" {
		u.Path = "/check"
	}
	q := u.Query()
	q.Set("user", username)
	q.Set("deviceid", deviceID)
	q.Set("from", "secondary")
	u.RawQuery = q.Encode()

	reqCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		return 0, 0, false, false
	}
	if token := strings.TrimSpace(os.Getenv("CHECKUSER_DEVICE_MASTER_TOKEN")); token != "" {
		req.Header.Set("X-Checkuser-Token", token)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, 0, false, false
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, 0, false, false
	}

	var out CheckUserOutput
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, 0, false, false
	}
	limit := out.Limit
	if out.DeviceLimit > 0 {
		limit = out.DeviceLimit
	}
	count := out.Connections
	if out.DeviceCount > 0 {
		count = out.DeviceCount
	}
	allowed := out.DeviceAllowed
	if out.DeviceStatus == "" {
		allowed = limit <= 0 || count <= limit
	}
	return count, limit, allowed, true
}
