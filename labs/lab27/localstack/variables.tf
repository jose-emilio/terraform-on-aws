# Entorno de despliegue: controla el hardening del script de bootstrap
# y el tipo de instancia seleccionado.
variable "env" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "El entorno debe ser 'dev' o 'prod'."
  }
}

variable "app_name" {
  type    = string
  default = "corp-lab27"
}

# Endpoint de la base de datos inyectado en el script de bootstrap via templatefile().
# En un proyecto real vendría de un output de otro módulo (p. ej. aws_db_instance).
variable "db_endpoint" {
  type    = string
  default = "db.corp-lab27.internal:5432"
}

# Tipo de instancia EC2. t3.micro está cubierto por la capa gratuita.
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
