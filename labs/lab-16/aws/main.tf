# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"
}

# --- Locals ---

locals {
  # Seleccionar las 3 primeras AZs disponibles en la región
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Mapa de subredes: 3 públicas (índices 0-2) y 3 privadas (índices 10-12).
  # El índice se usa en cidrsubnet() para calcular el rango IP sin solapamiento.
  subnets = {
    "public-1"  = { az_index = 0, subnet_index = 0, public = true }
    "public-2"  = { az_index = 1, subnet_index = 1, public = true }
    "public-3"  = { az_index = 2, subnet_index = 2, public = true }
    "private-1" = { az_index = 0, subnet_index = 10, public = false }
    "private-2" = { az_index = 1, subnet_index = 11, public = false }
    "private-3" = { az_index = 2, subnet_index = 12, public = false }
  }

  # Tags base aplicados a todos los recursos
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

# --- VPC ---

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-${var.project_name}"
  })

  lifecycle {
    postcondition {
      condition = can(regex(
        "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", self.cidr_block
      ))
      error_message = "El CIDR de la VPC debe pertenecer a un rango privado RFC 1918 (10.0.0.0/8, 172.16.0.0/12 o 192.168.0.0/16)."
    }
  }
}

# --- Subredes (6 en total: 3 públicas + 3 privadas) ---

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[each.value.az_index]

  # cidrsubnet(prefix, newbits, netnum)
  # Con /16 + 8 newbits = subredes /24 (256 IPs cada una).
  # subnet_index separa públicas (0,1,2) de privadas (10,11,12).
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.subnet_index)

  map_public_ip_on_launch = each.value.public

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${each.key}"
      Tier = each.value.public ? "public" : "private"
    },
    # Tags requeridos por EKS para el descubrimiento automático de subredes
    each.value.public ? {
      "kubernetes.io/role/elb"                            = "1"
      "kubernetes.io/cluster/${var.project_name}" = "shared"
    } : {
      "kubernetes.io/role/internal-elb"                   = "1"
      "kubernetes.io/cluster/${var.project_name}" = "shared"
    }
  )
}
