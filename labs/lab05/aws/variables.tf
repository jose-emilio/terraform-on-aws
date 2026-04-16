# Parámetros del entorno inyectados en la plantilla de User Data y en el
# archivo de configuración local generado con directivas %{if}.
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
  default = "corp-lab4"
}

# Endpoint de la base de datos inyectado en el script de bootstrap.
# En un proyecto real vendría de un output de otro módulo o de un data source.
variable "db_endpoint" {
  type    = string
  default = "db.corp-lab4.internal:5432"
}

# Lista de servicios a instalar en el servidor durante el bootstrap.
# La plantilla itera sobre esta lista con una directiva %{for}.
variable "services" {
  type    = list(string)
  default = ["nginx", "postgresql15", "amazon-cloudwatch-agent"]
}

# Ruta al archivo de clave pública SSH en la máquina local.
# file() leerá este archivo en tiempo de plan; debe existir antes de ejecutar Terraform.
variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}
