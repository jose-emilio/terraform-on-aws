# Configuración principal de la red. Agrupa en un objeto los parámetros
# relacionados para pasarlos como una unidad y validarlos de forma centralizada.
variable "network_config" {
  type = object({
    name       = string
    cidr_block = string
    env        = string
  })

  default = {
    name       = "corp-lab2"
    cidr_block = "10.0.0.0/16"
    env        = "dev"
  }

  # Garantiza que el nombre siga el estándar corporativo: prefijo "corp-"
  # seguido solo de letras minúsculas, números o guiones.
  validation {
    condition     = can(regex("^corp-[a-z0-9-]+$", var.network_config.name))
    error_message = "El nombre debe seguir el estándar corporativo: 'corp-' seguido de letras minúsculas, números o guiones."
  }

  # Restringe los entornos válidos para evitar despliegues en entornos no controlados
  validation {
    condition     = contains(["dev", "staging", "prod"], var.network_config.env)
    error_message = "El entorno debe ser 'dev', 'staging' o 'prod'."
  }
}

# Lista de reglas de firewall. Cada objeto define un puerto TCP y su descripción.
# El bloque dynamic en main.tf genera una regla ingress por cada elemento.
variable "firewall_rules" {
  type = list(object({
    port        = number
    description = string
  }))

  default = [
    { port = 22, description = "SSH" },
    { port = 80, description = "HTTP" },
    { port = 443, description = "HTTPS" },
  ]
}
