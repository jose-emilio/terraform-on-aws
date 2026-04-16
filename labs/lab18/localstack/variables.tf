variable "region" {
  type        = string
  description = "Region (fija en LocalStack)"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
  default     = "10.14.0.0/16"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab18"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}

variable "alb_ingress_ports" {
  type        = list(number)
  description = "Lista de puertos TCP que el ALB acepta desde Internet"
  default     = [80, 443]
}

variable "blocked_ip" {
  type        = string
  description = "CIDR de la IP maliciosa a bloquear en la NACL (ej: 203.0.113.0/32)"
  default     = "203.0.113.0/32"
}

variable "flow_log_retention_days" {
  type        = number
  description = "Dias de retencion de los VPC Flow Logs en CloudWatch"
  default     = 7
}
