# ===========================================================================
# Lab21 — Zonas Hospedadas Privadas y Resolución DNS (LocalStack)
# ===========================================================================
# Nota: LocalStack emula Route 53 a nivel de API pero no ejecuta resolución
# DNS real desde las "instancias EC2" emuladas. ELBv2 (ALB / NLB) sigue
# siendo una funcionalidad de pago en LocalStack: está incluida en los
# planes Base y Ultimate, pero NO en Community Edition ni en el nuevo plan
# gratuito Hobby (vigente desde marzo 2026, sustituye a Community). Por eso
# usamos un registro A con la IP privada de la instancia "web" en lugar de
# un Alias al ALB. Verificado contra docs.localstack.cloud/aws/services/elb/
# (revisado en mayo 2026).

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"
}

# --- Locals ---

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

# ===========================================================================
# VPC
# ===========================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-${var.project_name}"
  })
}

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${each.key}"
    Tier = "private"
  })
}

# ===========================================================================
# Instancias EC2
# ===========================================================================

resource "aws_instance" "web" {
  # AMI e instance_type alineados con la versión aws/ (AL2023 ARM + t4g.micro)
  # para mantener paridad. LocalStack no ejecuta tráfico ni user_data real.
  ami           = "ami-00000000000000000"
  instance_type = "t4g.micro"
  subnet_id     = aws_subnet.private["private-1"].id

  tags = merge(local.common_tags, {
    Name = "web-${var.project_name}"
  })
}

resource "aws_instance" "db" {
  # AMI e instance_type alineados con la versión aws/ (AL2023 ARM + t4g.micro)
  # para mantener paridad. LocalStack no ejecuta tráfico ni user_data real.
  ami           = "ami-00000000000000000"
  instance_type = "t4g.micro"
  subnet_id     = aws_subnet.private["private-1"].id
  private_ip    = cidrhost(aws_subnet.private["private-1"].cidr_block, 10)

  tags = merge(local.common_tags, {
    Name = "db-${var.project_name}"
  })
}

resource "aws_instance" "test" {
  # AMI e instance_type alineados con la versión aws/ (AL2023 ARM + t4g.micro)
  # para mantener paridad. LocalStack no ejecuta tráfico ni user_data real.
  ami           = "ami-00000000000000000"
  instance_type = "t4g.micro"
  subnet_id     = aws_subnet.private["private-2"].id

  tags = merge(local.common_tags, {
    Name = "test-${var.project_name}"
  })
}

# ===========================================================================
# Route 53 — Zona Hospedada Privada
# ===========================================================================

resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "phz-${var.internal_domain}-${var.project_name}"
  })
}

# Registro A: web.app.internal → IP privada de la instancia web
# (en AWS real se usaria un Alias al ALB, pero ELBv2 no esta en Community)
resource "aws_route53_record" "web" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "web.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.web.private_ip]
}

# Registro A: db.app.internal → IP privada fija
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.db.private_ip]
}
