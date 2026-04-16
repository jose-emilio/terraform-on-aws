# ===========================================================================
# Lab17 — Optimización de Salida a Internet y "NAT Tax" (LocalStack)
# ===========================================================================
# Nota: LocalStack emula la mayoría de recursos de red (VPC, subnets, IGW,
# NAT Gateway, VPC Endpoints) pero no ejecuta tráfico real. El objetivo
# de esta versión es validar la estructura de Terraform y el plan de
# despliegue sin incurrir en costes de AWS.
# La Instancia NAT no está disponible en LocalStack (requiere AMI real),
# por lo que use_nat_instance se ignora y siempre se despliega NAT Gateway.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"
}

# --- Locals ---

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  subnets = {
    "public-1"  = { az_index = 0, subnet_index = 0, public = true }
    "public-2"  = { az_index = 1, subnet_index = 1, public = true }
    "public-3"  = { az_index = 2, subnet_index = 2, public = true }
    "private-1" = { az_index = 0, subnet_index = 10, public = false }
    "private-2" = { az_index = 1, subnet_index = 11, public = false }
    "private-3" = { az_index = 2, subnet_index = 12, public = false }
  }

  public_subnets  = { for k, v in local.subnets : k => v if v.public }
  private_subnets = { for k, v in local.subnets : k => v if !v.public }

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
}

# --- Subredes ---

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[each.value.az_index]
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.subnet_index)
  map_public_ip_on_launch = each.value.public

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${each.key}"
    Tier = each.value.public ? "public" : "private"
  })
}

# ===========================================================================
# Internet Gateway
# ===========================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "igw-${var.project_name}"
  })
}

# --- Tabla de rutas pública ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# ===========================================================================
# NAT Gateway (siempre NAT Gateway en LocalStack, no soporta NAT Instance)
# ===========================================================================

resource "aws_eip" "nat" {
  for_each = local.public_subnets

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-${var.project_name}-${each.key}"
  })
}

resource "aws_nat_gateway" "main" {
  for_each = local.public_subnets

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.key].id

  tags = merge(local.common_tags, {
    Name = "natgw-${var.project_name}-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

# --- Tablas de rutas privadas (una por AZ para alta disponibilidad) ---

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt-${each.key}"
  })
}

resource "aws_route" "private_nat" {
  for_each = local.private_subnets

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # Cada subred privada usa el NAT Gateway de su misma AZ
  nat_gateway_id         = aws_nat_gateway.main["public-${each.value.az_index + 1}"].id
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# ===========================================================================
# VPC Gateway Endpoint para S3
# ===========================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    [for rt in aws_route_table.private : rt.id],
  )

  tags = merge(local.common_tags, {
    Name = "vpce-s3-${var.project_name}"
  })
}

# ===========================================================================
# Instancia de test — Verifica la conectividad NAT desde una subred privada
# ===========================================================================
# En LocalStack no se ejecuta tráfico real, pero valida la estructura de
# Terraform: security group, instancia en subred privada, dependencias NAT.

resource "aws_security_group" "test" {
  name        = "test-instance-${var.project_name}"
  description = "Instancia de test: solo trafico saliente"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente (necesario para SSM y pruebas NAT)"
  }

  tags = merge(local.common_tags, {
    Name = "test-instance-sg-${var.project_name}"
  })
}

resource "aws_instance" "test" {
  ami                    = "ami-00000000000000000" # AMI ficticia para LocalStack
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.this["private-1"].id
  vpc_security_group_ids = [aws_security_group.test.id]

  tags = merge(local.common_tags, {
    Name = "test-instance-${var.project_name}"
  })

  depends_on = [aws_route.private_nat]
}
