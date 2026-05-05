package middleware

import (
	"net/http"

	"portal/services"

	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
)

// JWTMiddleware returns an Echo middleware that validates the session cookie
// and redirects unauthenticated requests to /login.
func JWTMiddleware(slurm *services.SlurmService) echo.MiddlewareFunc {
	return echojwt.WithConfig(echojwt.Config{
		TokenLookup: "cookie:session",
		KeyFunc: func(token *jwt.Token) (interface{}, error) {
			return slurm.ReadKey()
		},
		ErrorHandler: func(c echo.Context, err error) error {
			return c.Redirect(http.StatusFound, "/login")
		},
	})
}
