# terraform.workspace devuelve el nombre del workspace activo ("default", "dev", "prod").
# Se usa como clave para seleccionar la configuración del entorno sin duplicar código.
locals {
  env = terraform.workspace

  # Mapa de configuración por entorno. El workspace "default" se trata como "dev"
  # para evitar despliegues accidentales de configuración de producción.
  config = {
    default = {
      vpc_cidr      = "10.0.0.0/16"
      subnet_cidr   = "10.0.1.0/24"
      instance_type = "t3.micro"
    }
    dev = {
      vpc_cidr      = "10.0.0.0/16"
      subnet_cidr   = "10.0.1.0/24"
      instance_type = "t3.micro"
    }
    prod = {
      vpc_cidr      = "10.1.0.0/16"
      subnet_cidr   = "10.1.1.0/24"
      instance_type = "t3.small"
    }
  }

  # lookup() selecciona la entrada del mapa correspondiente al workspace activo.
  # El tercer argumento es el valor por defecto si la clave no existe.
  env_config    = lookup(local.config, local.env, local.config["default"])
  vpc_cidr      = local.env_config.vpc_cidr
  subnet_cidr   = local.env_config.subnet_cidr
  instance_type = local.env_config.instance_type

  tags = {
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

# Bloque check: validación declarativa post-plan.
# Detecta inconsistencias en AMBAS direcciones:
#   - is_prod=true  en workspace dev  → operador activa prod en entorno equivocado
#   - is_prod=false en workspace prod → falta activar el flag de producción
# IMPORTANTE: check solo emite una ADVERTENCIA; el plan y el apply continúan.
# Para abortar el plan usa lifecycle { precondition } (ver recurso aws_vpc.main).
check "is_prod_workspace_consistency" {
  assert {
    condition     = var.is_prod == (terraform.workspace == "prod")
    error_message = "Posible inconsistencia: is_prod=${var.is_prod} en workspace '${terraform.workspace}'. Verifica que estás en el entorno correcto."
  }
}

# VPC del entorno. El CIDR varía según el workspace para evitar solapamientos
# cuando dev y prod existen simultáneamente en la misma cuenta.
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "vpc-${local.env}"
  })

  # precondition: SÍ aborta el plan si la condición falla.
  # Protege el caso más peligroso: desplegar is_prod=true fuera del workspace prod.
  # A diferencia del bloque check, este error impide que Terraform continúe.
  lifecycle {
    precondition {
      condition     = !(var.is_prod && terraform.workspace != "prod")
      error_message = "Seguridad: is_prod=true solo está permitido en el workspace 'prod'. Workspace activo: '${terraform.workspace}'."
    }
  }
}

# Subred principal del entorno. El CIDR es un subconjunto del rango de la VPC.
resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = local.subnet_cidr

  tags = merge(local.tags, {
    Name = "subnet-${local.env}"
  })
}
