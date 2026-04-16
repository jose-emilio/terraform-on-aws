variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab38"
}

variable "environment" {
  type        = string
  description = "Nombre del entorno"
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "dev"], var.environment)
    error_message = "El entorno debe ser 'production', 'staging' o 'dev'."
  }
}

# ── Etiquetas corporativas globales ───────────────────────────────────────────
# Se aplican a TODOS los recursos via default_tags del provider.
# Las etiquetas de departamento se fusionan con estas en cada recurso
# mediante merge() — ver locals.tf.
variable "company_tags" {
  type = object({
    cost_center = string
    owner       = string
  })
  description = "Etiquetas corporativas obligatorias presentes en todos los recursos"
  default = {
    cost_center = "platform-infra"
    owner       = "platform-team@example.com"
  }
}

# ── Definicion de VPCs con subredes anidadas — Flatten Pattern ────────────────
# Esta variable representa una estructura real de configuracion de red:
# multiples VPCs, cada una con un numero variable de subredes.
#
# El problema: for_each no puede iterar directamente sobre un mapa anidado
# (VPC → subredes). La solucion es el Flatten Pattern: aplanar la estructura
# en una lista plana de objetos (un objeto por subred) antes de iterar.
#
# Ver locals.tf para la implementacion del flatten.
variable "vpc_config" {
  type = map(object({
    cidr_block = string
    subnets = map(object({
      cidr_block        = string
      availability_zone = string
      public            = bool
      department_tags = object({
        department   = string
        team         = string
        billing_code = string
      })
    }))
  }))
  description = <<-EOT
    Mapa de VPCs con sus subredes anidadas. Cada VPC contiene un mapa de
    subredes identificadas por nombre logico. El Flatten Pattern transforma
    esta estructura en una lista plana apta para for_each.
  EOT
  default = {
    "networking" = {
      cidr_block = "10.39.0.0/16"
      subnets = {
        "public-a" = {
          cidr_block        = "10.39.1.0/24"
          availability_zone = "us-east-1a"
          public            = true
          department_tags = {
            department   = "networking"
            team         = "net-ops"
            billing_code = "NET-001"
          }
        }
        "public-b" = {
          cidr_block        = "10.39.2.0/24"
          availability_zone = "us-east-1b"
          public            = true
          department_tags = {
            department   = "networking"
            team         = "net-ops"
            billing_code = "NET-001"
          }
        }
        "private-a" = {
          cidr_block        = "10.39.10.0/24"
          availability_zone = "us-east-1a"
          public            = false
          department_tags = {
            department   = "networking"
            team         = "net-ops"
            billing_code = "NET-002"
          }
        }
      }
    }
    "data" = {
      cidr_block = "10.40.0.0/16"
      subnets = {
        "db-a" = {
          cidr_block        = "10.40.1.0/24"
          availability_zone = "us-east-1a"
          public            = false
          department_tags = {
            department   = "data"
            team         = "data-eng"
            billing_code = "DAT-001"
          }
        }
        "db-b" = {
          cidr_block        = "10.40.2.0/24"
          availability_zone = "us-east-1b"
          public            = false
          department_tags = {
            department   = "data"
            team         = "data-eng"
            billing_code = "DAT-001"
          }
        }
      }
    }
  }
}

# ── Configuracion de la instancia de monitoreo — optional() ──────────────────
# Demuestra el uso de optional() para atributos opcionales con valores por
# defecto. Si el operador no especifica un atributo, Terraform usa el default
# en lugar de exigir un valor o producir null.
variable "monitoring_config" {
  type = object({
    enabled       = bool
    instance_type = optional(string, "t4g.micro")
    # allowed_azs: lista de zonas de disponibilidad autorizadas.
    # La precondition valida que la AZ elegida este en esta lista.
    allowed_azs   = optional(list(string), ["us-east-1a", "us-east-1b", "us-east-1c"])
    # availability_zone: zona donde se desplegara la instancia.
    # Debe ser una de las listadas en allowed_azs.
    availability_zone = optional(string, "us-east-1a")
    # associate_public_ip: la postcondition verifica que la IP publica
    # se asigno correctamente cuando este atributo es true.
    associate_public_ip = optional(bool, true)
    # alarm_email: si se proporciona, crea un SNS topic y una alarma de CPU.
    alarm_email   = optional(string, null)
    # root_volume_size_gb: permite ajustar el disco raiz sin cambiar el modulo.
    root_volume_size_gb = optional(number, 20)
  })
  description = <<-EOT
    Configuracion de la instancia de monitoreo. Todos los campos excepto
    'enabled' son opcionales y tienen valores por defecto razonables.
    Demuestra el uso de optional() para configuraciones flexibles sin
    obligar al operador a especificar cada atributo.
  EOT
  default = {
    enabled = true
  }
}
