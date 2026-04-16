variable "region" {
  type    = string
  default = "us-east-1"
}

variable "app_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 de la aplicación"
}

# Configuración del provider — se sobreescriben según el entorno con -var-file
variable "aws_access_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "skip_credentials_validation" {
  type    = bool
  default = false
}

variable "skip_metadata_api_check" {
  type    = bool
  default = false
}

variable "skip_requesting_account_id" {
  type    = bool
  default = false
}

variable "s3_endpoint" {
  type        = string
  default     = ""
  description = "Endpoint S3 personalizado. Vacío = endpoints por defecto de AWS."
}
