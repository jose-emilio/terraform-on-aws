variable "region" {
  type        = string
  description = "Region de AWS donde se despliega la infraestructura del pipeline."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del laboratorio."
  default     = "lab45"
}

variable "approval_email" {
  type        = string
  description = "Direccion de correo que recibe las solicitudes de aprobacion manual del pipeline."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.approval_email))
    error_message = "El valor debe ser una direccion de correo electronico valida."
  }
}

variable "terraform_version" {
  type        = string
  description = "Version de Terraform que los proyectos CodeBuild descargan e instalan."
  default     = "1.14.8"
}

variable "tflint_version" {
  type        = string
  description = "Version de TFLint que los proyectos CodeBuild descargan e instalan."
  default     = "0.61.0"
}

variable "checkov_version" {
  type        = string
  description = "Version de Checkov que los proyectos CodeBuild instalan via pip."
  default     = "3.2.519"
}

variable "opa_version" {
  type        = string
  description = "Version de OPA que el proyecto PolicyCheck descarga e instala."
  default     = "1.15.2"
}

variable "max_destroys_threshold" {
  type        = number
  description = "Numero maximo de recursos destruidos que el inspector Lambda permite sin bloquear el pipeline. -1 para desactivar la comprobacion."
  default     = -1

  validation {
    condition     = var.max_destroys_threshold >= -1
    error_message = "El umbral debe ser -1 (sin limite) o un entero positivo."
  }
}

variable "branch" {
  type        = string
  description = "Rama del repositorio CodeCommit que dispara el pipeline."
  default     = "main"
}

variable "log_retention_days" {
  type        = number
  description = "Dias de retencion de los grupos de logs de CloudWatch de los proyectos CodeBuild."
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "El valor debe ser uno de los periodos de retencion validos de CloudWatch Logs."
  }
}
