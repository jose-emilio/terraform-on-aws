variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab29"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "desired_count" {
  type        = number
  description = "Número de tareas Fargate que ECS mantendrá en ejecución"
  default     = 2
}

variable "container_image" {
  type        = string
  description = "Imagen del contenedor a desplegar. Usa la imagen pública de nginx para pruebas inmediatas o sustitúyela por la URL de tu repositorio ECR tras hacer push."
  default     = "nginx:alpine"
}

variable "api_key" {
  type        = string
  description = "Clave de API almacenada en SSM Parameter Store como SecureString. ECS la inyecta como la variable de entorno API_KEY en cada contenedor."
  sensitive   = true
  default     = "mi-clave-de-api-secreta-lab29"
}
