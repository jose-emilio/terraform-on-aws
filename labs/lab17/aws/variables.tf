variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
  default     = "10.13.0.0/16"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab17"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}

variable "use_nat_instance" {
  type        = bool
  description = "true = Instancia NAT EC2 (dev, ahorro ~75%); false = NAT Gateway (producción, alta disponibilidad)"
  default     = false
}