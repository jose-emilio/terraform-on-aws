variable "project" {
  type        = string
  description = "Prefijo para nombrar los recursos del modulo"
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas comunes a todos los recursos del modulo"
}

variable "vpc_id" {
  type        = string
  description = "ID de la VPC donde se despliega la instancia"
}

variable "subnet_id" {
  type        = string
  description = "ID de la subnet donde se lanza la instancia"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2"
  default     = "t3.micro"
}

variable "ebs_iops" {
  type        = number
  description = "IOPS del volumen EBS de datos (gp3)"
  default     = 6000
}

variable "ebs_throughput" {
  type        = number
  description = "Throughput en MB/s del volumen EBS de datos (gp3)"
  default     = 400
}

variable "ebs_size_gb" {
  type        = number
  description = "Tamanyo en GB del volumen EBS de datos"
  default     = 100
}
