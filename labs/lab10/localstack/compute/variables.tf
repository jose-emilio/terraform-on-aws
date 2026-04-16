variable "network_state_path" {
  type        = string
  default     = "../network/terraform.tfstate"
  description = "Ruta relativa al archivo de estado de la capa de red (backend local)."
}
