variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab15"
}

variable "github_org" {
  type        = string
  description = "Nombre de la organización o usuario de GitHub propietario del repositorio"
}

variable "github_repo" {
  type        = string
  description = "Nombre del repositorio de GitHub (sin la parte de organización)"
}

variable "allowed_ref" {
  type        = string
  description = <<-EOT
    Rama o patrón de refs que puede asumir el rol vía OIDC.
    Usa '*' para permitir cualquier rama/tag o especifica 'ref:refs/heads/main'
    para restringir solo a la rama main.
  EOT
  default     = "*"
}
