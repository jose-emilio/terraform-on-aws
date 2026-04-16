variable "region" {
  type        = string
  description = "Region AWS donde se despliegan los recursos"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab36"
}

variable "app_instance_type" {
  type        = string
  description = "Tipo de instancia EC2 para la aplicacion web (ARM64)"
  default     = "t4g.small"
}

variable "redis_node_type" {
  type        = string
  description = "Tipo de nodo de ElastiCache Redis"
  default     = "cache.t3.micro"
}

variable "cache_ttl" {
  type        = number
  description = "TTL en segundos para las entradas de Redis"
  default     = 60
}
