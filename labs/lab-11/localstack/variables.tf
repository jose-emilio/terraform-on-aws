variable "region" {
  type        = string
  description = "Región (fija en LocalStack)"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
  default     = "10.11.0.0/16"
}
