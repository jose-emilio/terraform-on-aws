variable "region" {
  type        = string
  description = "Region de AWS donde se despliega la infraestructura del pipeline."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del laboratorio."
  default     = "lab43"
}

variable "codecommit_repo_name" {
  type        = string
  description = "Nombre del repositorio CodeCommit que almacena el codigo Terraform objetivo."
  default     = "terraform-code"
}

variable "ecr_repo_name" {
  type        = string
  description = "Nombre del repositorio ECR que aloja la imagen custom del runner de IaC."
  default     = "iac-runner"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9/_.-]{1,254}$", var.ecr_repo_name))
    error_message = "El nombre del repositorio ECR debe tener entre 2 y 256 caracteres y solo puede contener letras minusculas, numeros, guiones, guiones bajos, puntos y barras."
  }
}

variable "codebuild_project_name" {
  type        = string
  description = "Nombre del proyecto de CodeBuild que orquesta las validaciones y el plan."
  default     = "iac-runner"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,254}$", var.codebuild_project_name))
    error_message = "El nombre del proyecto CodeBuild solo puede contener letras, numeros, guiones y guiones bajos."
  }
}

# ── Versiones pinneadas de las herramientas del runner ────────────────────────
#
# Pinnear versiones es fundamental para la reproducibilidad del pipeline:
# la misma imagen produce siempre el mismo resultado, independientemente
# de cuando se construya. Una actualizacion de herramienta es un cambio
# explicito y revisado, no un efecto colateral de un build.

variable "terraform_version" {
  type        = string
  description = "Version de Terraform incluida en la imagen del runner. Usar version semántica exacta."
  default     = "1.9.5"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.terraform_version))
    error_message = "La version de Terraform debe seguir el patron MAJOR.MINOR.PATCH (p. ej. 1.9.5)."
  }
}

variable "tflint_version" {
  type        = string
  description = "Version de TFLint incluida en la imagen del runner."
  default     = "0.52.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.tflint_version))
    error_message = "La version de TFLint debe seguir el patron MAJOR.MINOR.PATCH."
  }
}

variable "tfsec_version" {
  type        = string
  description = "Version de tfsec incluida en la imagen del runner."
  default     = "1.28.6"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.tfsec_version))
    error_message = "La version de tfsec debe seguir el patron MAJOR.MINOR.PATCH."
  }
}

variable "checkov_version" {
  type        = string
  description = "Version de Checkov (paquete pip) incluida en la imagen del runner."
  default     = "3.2.231"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.checkov_version))
    error_message = "La version de Checkov debe seguir el patron MAJOR.MINOR.PATCH."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Dias de retencion de los logs de CodeBuild en CloudWatch."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "El valor debe ser uno de los periodos de retencion validos de CloudWatch Logs."
  }
}

variable "ecr_max_images" {
  type        = number
  description = "Numero maximo de imagenes etiquetadas a mantener en el repositorio ECR. Las mas antiguas se eliminan automaticamente."
  default     = 10

  validation {
    condition     = var.ecr_max_images >= 1 && var.ecr_max_images <= 100
    error_message = "El numero maximo de imagenes debe estar entre 1 y 100."
  }
}
