variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab13"
}

variable "admin_principal_arns" {
  type        = list(string)
  description = <<-EOT
    ARNs de los administradores de la CMK (usuarios o roles IAM).
    Si se deja vacío, Terraform usará el ARN del caller actual.
    Ejemplo: ["arn:aws:iam::123456789012:user/alice"]
  EOT
  default     = []
}

variable "app_principal_arns" {
  type        = list(string)
  description = <<-EOT
    ARNs de los usuarios/roles que pueden usar la CMK para cifrar y descifrar
    (aplicaciones, servicios, instancias EC2...).
    Si se deja vacío, el bloque de usuarios finales se omite de la Key Policy.
    Ejemplo: ["arn:aws:iam::123456789012:role/my-app-role"]
  EOT
  default     = []
}

variable "ebs_volume_size_gb" {
  type        = number
  description = "Tamaño del volumen EBS en GiB"
  default     = 10
}

variable "availability_zone" {
  type        = string
  description = "Zona de disponibilidad para el volumen EBS"
  default     = "us-east-1a"
}
