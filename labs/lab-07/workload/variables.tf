variable "region" {
  type    = string
  default = "us-east-1"
}

variable "app_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 de la aplicación"
}
