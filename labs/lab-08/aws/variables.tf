variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3 creado fuera de Terraform que se va a importar"
}
