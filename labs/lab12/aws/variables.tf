variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab12"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2. t4g usa arquitectura ARM64 (Graviton)"
  default     = "t4g.micro"
}
