variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "lab41"
}

variable "repo_name" {
  type        = string
  description = "Nombre del repositorio CodeCommit. Sera la Fuente de la Verdad del equipo."
  default     = "platform-backend"
}

variable "developer_usernames" {
  type        = list(string)
  description = "Usuarios IAM del equipo de desarrollo. Pueden hacer push a develop y feature/*."
  default     = ["alice-dev", "bob-dev"]

  validation {
    condition     = length(var.developer_usernames) > 0
    error_message = "Debe haber al menos un desarrollador."
  }
}

variable "tech_lead_usernames" {
  type        = list(string)
  description = "Usuarios IAM de lideres tecnicos. Pueden aprobar PRs y hacer merge a main."
  default     = ["carlos-lead", "diana-lead"]

  validation {
    condition     = length(var.tech_lead_usernames) > 0
    error_message = "Debe haber al menos un lider tecnico para el pool de aprobacion."
  }
}

variable "protected_branches" {
  type        = list(string)
  description = <<-EOT
    Nombres de las ramas protegidas (sin el prefijo refs/heads/).
    Los desarrolladores no podran hacer push directo ni merge a estas ramas.
    Acepta wildcards de IAM StringLike: "release/*" protege todas las ramas release/.

    Ejemplos:
      ["main"]                   # solo main
      ["main", "release/*"]      # main + todas las release/x.y.z
  EOT
  default     = ["main"]

  validation {
    condition     = length(var.protected_branches) > 0
    error_message = "Debe haber al menos una rama protegida."
  }
}

variable "slack_webhook_url" {
  type        = string
  description = <<-EOT
    URL del webhook de entrada de Slack o Teams para recibir notificaciones de
    Pull Requests. El SNS Topic enviara un POST con el cuerpo del evento cuando
    se cree o actualice un PR.

    Slack (Incoming Webhooks App):
      https://hooks.slack.com/services/T.../B.../...

    Microsoft Teams (Incoming Webhook connector):
      https://<tenant>.webhook.office.com/webhookb2/...

    Para pruebas sin configurar una integracion real, usa webhook.site:
      1. Ve a https://webhook.site
      2. Copia la URL unica generada
      3. Pasala como valor de esta variable

    Deja en blanco ("") para omitir la suscripcion HTTPS y usar solo email.
  EOT
  default   = ""
  sensitive = true

  validation {
    condition     = var.slack_webhook_url == "" || can(regex("^https://", var.slack_webhook_url))
    error_message = "El webhook URL debe comenzar con https:// o estar vacio."
  }
}

variable "notification_email" {
  type        = string
  description = <<-EOT
    Direccion de correo para recibir notificaciones de Pull Requests por email.
    AWS enviara un correo de confirmacion: la suscripcion no estara activa hasta
    que el destinatario haga clic en el enlace de confirmacion.

    Deja en blanco ("") para omitir la suscripcion de email.
  EOT
  default = ""

  validation {
    condition     = var.notification_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.notification_email))
    error_message = "El email debe tener formato valido (usuario@dominio.com) o estar vacio."
  }
}

variable "min_approvals_required" {
  type        = number
  description = "Numero minimo de aprobaciones de tech lead requeridas antes de poder hacer merge a main."
  default     = 1

  validation {
    condition     = var.min_approvals_required >= 1
    error_message = "Se requiere al menos 1 aprobacion."
  }
}
