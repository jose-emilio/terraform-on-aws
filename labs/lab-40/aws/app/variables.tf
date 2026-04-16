variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "lab40"
}

variable "state_bucket" {
  type        = string
  description = <<-EOT
    Nombre del bucket S3 que almacena el estado del proyecto network/.
    Debe coincidir con el bucket usado al inicializar network/:
      terraform-state-labs-<ACCOUNT_ID>
  EOT
}
