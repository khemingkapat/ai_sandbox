package main

import (
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// RoleLevel returns numeric hierarchy for role comparison:
// student (1) < instructor (2) < admin (3)
func RoleLevel(role string) int {
	switch strings.ToLower(strings.TrimSpace(role)) {
	case "admin":
		return 3
	case "instructor", "ta", "teacher":
		return 2
	case "student":
		return 1
	default:
		return 1
	}
}

// RequireRole enforces minimum role level for route access.
func RequireRole(minRole string) echo.MiddlewareFunc {
	minLevel := RoleLevel(minRole)
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			ctx, ok := c.Get("unified_user").(*UnifiedUserContext)
			if !ok || ctx == nil {
				return c.JSON(http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
			}
			if RoleLevel(ctx.Role) < minLevel {
				return c.JSON(http.StatusForbidden, map[string]string{
					"error": "Forbidden: insufficient role privileges",
				})
			}
			return next(c)
		}
	}
}

// TenantIsolationMiddleware ensures a student cannot access another student's :user workspace.
// Admins are permitted to bypass this check.
func TenantIsolationMiddleware() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			userParam := c.Param("user")
			if userParam == "" {
				return next(c)
			}

			ctx, ok := c.Get("unified_user").(*UnifiedUserContext)
			if !ok || ctx == nil {
				return c.String(http.StatusUnauthorized, "Unauthorized")
			}

			// Admin bypass
			if strings.EqualFold(ctx.Role, "admin") {
				return next(c)
			}

			// Compare student ID with URL user parameter
			if ctx.StudentID != userParam {
				c.Response().Header().Set("X-Denial-Reason", "cross-tenant-isolation")
				return c.String(http.StatusForbidden, "Forbidden: cross-tenant access denied")
			}

			return next(c)
		}
	}
}

// UnifiedJWTMiddleware extracts and validates sandbox_token or session cookie or Bearer token,
// populating "unified_user" in the echo.Context.
func UnifiedJWTMiddleware(verifier *UnifiedJWTVerifier) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			tokenStr := ""
			if ck, err := c.Cookie("sandbox_token"); err == nil && ck.Value != "" {
				tokenStr = ck.Value
			}
			if tokenStr == "" {
				authHdr := c.Request().Header.Get("Authorization")
				if strings.HasPrefix(authHdr, "Bearer ") {
					tokenStr = strings.TrimPrefix(authHdr, "Bearer ")
				}
			}
			if tokenStr == "" {
				if ck, err := c.Cookie("session"); err == nil && ck.Value != "" {
					tokenStr = ck.Value
				}
			}

			if tokenStr == "" {
				if strings.Contains(c.Request().Header.Get("Accept"), "text/html") {
					return c.Redirect(http.StatusFound, "/login")
				}
				return c.JSON(http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
			}

			var userCtx *UnifiedUserContext
			if verifier != nil {
				u, err := verifier.VerifyUnifiedToken(tokenStr)
				if err == nil {
					userCtx = u
				}
			}

			// Fallback to Slurm session token
			if userCtx == nil {
				if slurmKey, err := readSlurmKey(); err == nil && len(slurmKey) > 0 {
					stk, pErr := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
						return slurmKey, nil
					})
					if pErr == nil && stk.Valid {
						if clm, ok := stk.Claims.(jwt.MapClaims); ok {
							sun, _ := clm["sun"].(string)
							if sun != "" {
								userCtx = &UnifiedUserContext{
									StudentID: sun,
									TenantID:  sun,
									Role:      "student",
									RawClaims: clm,
								}
								// Also set echo-jwt compatibility key "user"
								c.Set("user", stk)
							}
						}
					}
				}
			}

			if userCtx == nil {
				if strings.Contains(c.Request().Header.Get("Accept"), "text/html") {
					return c.Redirect(http.StatusFound, "/login")
				}
				return c.JSON(http.StatusUnauthorized, map[string]string{"error": "Invalid token"})
			}

			c.Set("unified_user", userCtx)
			if c.Get("user") == nil {
				// Check if session cookie exists for Slurm context
				if ck, err := c.Cookie("session"); err == nil && ck.Value != "" {
					if slurmKey, err := readSlurmKey(); err == nil && len(slurmKey) > 0 {
						if stk, pErr := jwt.Parse(ck.Value, func(t *jwt.Token) (interface{}, error) {
							return slurmKey, nil
						}); pErr == nil && stk.Valid {
							c.Set("user", stk)
						}
					}
				}
				if c.Get("user") == nil {
					// Fallback synthesized token for echo-jwt compatibility
					synthClaims := jwt.MapClaims{
						"sun": userCtx.StudentID,
						"prj": "project1",
					}
					c.Set("user", jwt.NewWithClaims(jwt.SigningMethodHS256, synthClaims))
				}
			}
			return next(c)
		}
	}
}
