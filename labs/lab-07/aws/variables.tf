variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3 creado en el Lab02 (formato: terraform-state-labs-<ACCOUNT_ID>)"
}

variable "table_name" {
  type    = string
  default = "terraform-state-lock"
}
