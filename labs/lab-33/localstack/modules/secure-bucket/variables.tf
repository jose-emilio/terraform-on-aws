variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3"
}

variable "project" {
  type        = string
  description = "Prefijo del proyecto"
}

variable "tags" {
  type        = map(string)
  default     = {}
}

variable "vpc_endpoint_id" {
  type        = string
  description = "ID del VPC Gateway Endpoint (aceptado pero no aplicado en LocalStack Community)"
}

variable "transition_days" {
  type    = number
  default = 90
}

variable "expiration_days" {
  type    = number
  default = 365
}
