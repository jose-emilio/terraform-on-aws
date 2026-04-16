variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "lab42"
}

variable "domain_name" {
  type        = string
  description = "Nombre del dominio CodeArtifact. Debe ser unico dentro de la cuenta y region."
  default     = "supply-chain"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,47}[a-z0-9]$", var.domain_name))
    error_message = "El nombre del dominio solo puede contener letras minusculas, numeros y guiones, entre 2 y 50 caracteres."
  }
}

variable "repo_name" {
  type        = string
  description = "Nombre del repositorio CodeArtifact que almacena los modulos Terraform."
  default     = "terraform-modules"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,99}[a-z0-9]$", var.repo_name))
    error_message = "El nombre del repositorio solo puede contener letras minusculas, numeros y guiones, entre 2 y 100 caracteres."
  }
}

variable "publisher_usernames" {
  type        = list(string)
  description = "Usuarios IAM con permisos de publicacion de paquetes (rol CI/CD)."
  default     = ["ci-publisher"]

  validation {
    condition     = length(var.publisher_usernames) > 0
    error_message = "Debe haber al menos un usuario publicador."
  }
}

variable "consumer_usernames" {
  type        = list(string)
  description = "Usuarios IAM con permisos de lectura de paquetes (desarrolladores o pipelines de despliegue)."
  default     = ["ci-consumer"]

  validation {
    condition     = length(var.consumer_usernames) > 0
    error_message = "Debe haber al menos un usuario consumidor."
  }
}
