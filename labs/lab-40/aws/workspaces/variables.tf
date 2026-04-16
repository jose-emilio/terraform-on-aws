variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab40"
}

variable "environments" {
  type        = list(string)
  description = "Lista de entornos para los que se crea un workspace S3"
  default     = ["dev", "staging", "prod"]
}

# ── Parametros de configuracion de la aplicacion ──────────────────────────────
# 20 entradas sin dependencias entre si. Se usan en el Paso 4 para medir
# el impacto del flag -parallelism comparando 10 workers vs 30 workers.
variable "config_params" {
  type        = map(string)
  description = "Mapa clave→valor de parametros de configuracion de la aplicacion"
  default = {
    "app/log-level"           = "INFO"
    "app/max-connections"     = "100"
    "app/timeout-seconds"     = "30"
    "app/retry-attempts"      = "3"
    "app/cache-ttl"           = "300"
    "db/pool-size"            = "10"
    "db/query-timeout"        = "5000"
    "db/max-idle-connections" = "5"
    "db/connect-string"       = "jdbc:postgresql://db.internal:5432/app"
    "db/ssl-mode"             = "require"
    "cdn/cache-control"       = "max-age=3600"
    "cdn/gzip-enabled"        = "true"
    "cdn/origin-timeout"      = "10"
    "auth/token-expiry"       = "3600"
    "auth/refresh-expiry"     = "86400"
    "auth/max-sessions"       = "5"
    "notifications/email"     = "enabled"
    "notifications/slack"     = "disabled"
    "feature/beta-api"        = "disabled"
    "feature/analytics"       = "enabled"
  }
}
