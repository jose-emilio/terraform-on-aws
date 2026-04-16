variable "region" {
  type    = string
  default = "us-east-1"
}

variable "network_state_bucket" {
  type        = string
  description = "Nombre del bucket S3 que almacena el estado de la capa de red."
}

variable "network_state_key" {
  type        = string
  default     = "lab10/network/terraform.tfstate"
  description = "Clave S3 del archivo de estado de la capa de red."
}
