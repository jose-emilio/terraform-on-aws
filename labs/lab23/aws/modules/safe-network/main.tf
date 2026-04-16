# ===========================================================================
# Módulo safe-network — VPC con postcondición RFC 1918
# ===========================================================================
# Crea una VPC y valida con postcondition que el CIDR asignado sea
# efectivamente un rango privado RFC 1918. Esto protege contra la
# creación accidental de redes con IPs públicas.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# --- Locals ---

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  default_tags = {
    ManagedBy = "terraform"
    Module    = "safe-network"
  }

  effective_tags = merge(local.default_tags, var.tags)
}

# --- VPC con postcondición ---

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.effective_tags, {
    Name = "vpc-${var.project_name}"
  })

  lifecycle {
    postcondition {
      condition = anytrue([
        can(regex("^10\\.", self.cidr_block)),
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", self.cidr_block)),
        can(regex("^192\\.168\\.", self.cidr_block)),
      ])
      error_message = "El CIDR ${self.cidr_block} no es un rango privado RFC 1918. Usa 10.0.0.0/8, 172.16.0.0/12, o 192.168.0.0/16."
    }
  }
}

# --- Subredes privadas ---

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 8, each.value.index)

  tags = merge(local.effective_tags, {
    Name = "${var.project_name}-${each.key}"
    Tier = "private"
  })
}
