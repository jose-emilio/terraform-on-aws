# ===========================================================================
# Lab19 — Conectividad Punto a Punto con VPC Peering
# ===========================================================================
# Topologia:
#   vpc-app (10.15.0.0/16) ◄──peering──► vpc-db  (10.16.0.0/16)
#   vpc-app (10.15.0.0/16) ◄──peering──► vpc-c   (10.17.0.0/16)
#   vpc-c   (10.17.0.0/16)  ── ✗ ──      vpc-db  (sin peering, no transitivo)
#
# vpc-app tiene IGW + NAT Gateway para salida a Internet.
# vpc-db y vpc-c salen a Internet a traves de vpc-app via peering.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# AMI Amazon Linux 2023 estandar (NO minimal): incluye SSM Agent preinstalado.
# Las instancias en vpc-db y vpc-c no tienen salida a Internet para descargar
# paquetes, por lo que necesitan una AMI que ya incluya el agente.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
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
# VPC app — Con IGW + NAT Gateway (salida a Internet centralizada)
# ===========================================================================

resource "aws_vpc" "app" {
  cidr_block           = var.app_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-app-${var.project_name}"
  })
}

# --- Subredes publicas ---

resource "aws_subnet" "app_public" {
  for_each = { for idx, az in local.azs : "public-${idx + 1}" => { az = az, index = idx } }

  vpc_id                  = aws_vpc.app.id
  availability_zone       = each.value.az
  cidr_block              = cidrsubnet(aws_vpc.app.cidr_block, 8, each.value.index)
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "app-${each.key}-${var.project_name}"
    Tier = "public"
  })
}

# --- Subredes privadas ---

resource "aws_subnet" "app_private" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.app.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.app.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "app-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "app" {
  vpc_id = aws_vpc.app.id

  tags = merge(local.common_tags, {
    Name = "igw-app-${var.project_name}"
  })
}

# --- Tabla de rutas publica ---

resource "aws_route_table" "app_public" {
  vpc_id = aws_vpc.app.id

  tags = merge(local.common_tags, {
    Name = "app-public-rt-${var.project_name}"
  })
}

resource "aws_route" "app_public_internet" {
  route_table_id         = aws_route_table.app_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.app.id
}

resource "aws_route_table_association" "app_public" {
  for_each = aws_subnet.app_public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app_public.id
}

# --- NAT Gateway ---

resource "aws_eip" "nat_app" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-app-${var.project_name}"
  })
}

resource "aws_nat_gateway" "app" {
  allocation_id = aws_eip.nat_app.id
  subnet_id     = aws_subnet.app_public["public-1"].id

  tags = merge(local.common_tags, {
    Name = "natgw-app-${var.project_name}"
  })

  depends_on = [aws_internet_gateway.app]
}

# --- Tabla de rutas privada ---

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.app.id

  tags = merge(local.common_tags, {
    Name = "app-private-rt-${var.project_name}"
  })
}

resource "aws_route" "app_private_nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.app.id
}

resource "aws_route_table_association" "app_private" {
  for_each = aws_subnet.app_private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

# ===========================================================================
# VPC db — Solo subredes privadas (sale a Internet via peering con app)
# ===========================================================================

resource "aws_vpc" "db" {
  cidr_block           = var.db_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-db-${var.project_name}"
  })
}

resource "aws_subnet" "db" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.db.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.db.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "db-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.db.id

  tags = merge(local.common_tags, {
    Name = "db-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

# ===========================================================================
# VPC C — Solo subredes privadas (demuestra no transitividad)
# ===========================================================================

resource "aws_vpc" "c" {
  cidr_block           = var.c_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-c-${var.project_name}"
  })
}

resource "aws_subnet" "c" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.c.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.c.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "c-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "c" {
  vpc_id = aws_vpc.c.id

  tags = merge(local.common_tags, {
    Name = "c-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "c" {
  for_each = aws_subnet.c

  subnet_id      = each.value.id
  route_table_id = aws_route_table.c.id
}

# ===========================================================================
# VPC Peering — app ↔ db
# ===========================================================================

resource "aws_vpc_peering_connection" "app_to_db" {
  vpc_id      = aws_vpc.app.id
  peer_vpc_id = aws_vpc.db.id
  auto_accept = true

  tags = merge(local.common_tags, {
    Name = "peering-app-db-${var.project_name}"
  })
}

# --- Rutas bidireccionales app ↔ db ---

# app → db
resource "aws_route" "app_to_db" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = var.db_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}

# db → app (solo trafico hacia el CIDR de app, no ruta por defecto)
resource "aws_route" "db_to_app" {
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = var.app_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}

# ===========================================================================
# VPC Peering — app ↔ vpc-c
# ===========================================================================

resource "aws_vpc_peering_connection" "app_to_c" {
  vpc_id      = aws_vpc.app.id
  peer_vpc_id = aws_vpc.c.id
  auto_accept = true

  tags = merge(local.common_tags, {
    Name = "peering-app-c-${var.project_name}"
  })
}

# --- Rutas bidireccionales app ↔ vpc-c ---

# app → vpc-c
resource "aws_route" "app_to_c" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = var.c_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_c.id
}

# vpc-c → app (solo trafico hacia el CIDR de app, no ruta por defecto)
resource "aws_route" "c_to_app" {
  route_table_id            = aws_route_table.c.id
  destination_cidr_block    = var.app_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_c.id
}

# ===========================================================================
# VPC Interface Endpoints para SSM — vpc-db y vpc-c
# ===========================================================================
# El peering no permite reenviar trafico a Internet. Las instancias usan
# una AMI con SSM Agent preinstalado (AL2023 estandar), pero el agente
# necesita conectarse a los endpoints de Systems Manager para registrarse.
# Los VPC Interface Endpoints (PrivateLink) permiten esa conexion sin Internet.

resource "aws_security_group" "ssm_endpoints_db" {
  name        = "ssm-endpoints-db-${var.project_name}"
  description = "HTTPS desde la VPC hacia los endpoints SSM"
  vpc_id      = aws_vpc.db.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.db_cidr]
    description = "HTTPS desde la VPC"
  }

  tags = merge(local.common_tags, {
    Name = "ssm-endpoints-db-sg-${var.project_name}"
  })
}

resource "aws_security_group" "ssm_endpoints_c" {
  name        = "ssm-endpoints-c-${var.project_name}"
  description = "HTTPS desde la VPC hacia los endpoints SSM"
  vpc_id      = aws_vpc.c.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.c_cidr]
    description = "HTTPS desde la VPC"
  }

  tags = merge(local.common_tags, {
    Name = "ssm-endpoints-c-sg-${var.project_name}"
  })
}

resource "aws_vpc_endpoint" "db_ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.db.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k, s in aws_subnet.db : s.id]
  security_group_ids  = [aws_security_group.ssm_endpoints_db.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "vpce-${each.key}-db-${var.project_name}"
  })
}

resource "aws_vpc_endpoint" "c_ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.c.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k, s in aws_subnet.c : s.id]
  security_group_ids  = [aws_security_group.ssm_endpoints_c.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "vpce-${each.key}-c-${var.project_name}"
  })
}

# ===========================================================================
# IAM Role SSM — Para conectarse a las instancias de test
# ===========================================================================

resource "aws_iam_role" "ssm" {
  name = "ssm-instance-role-${var.project_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "ssm-instance-profile-${var.project_name}"
  role = aws_iam_role.ssm.name

  tags = local.common_tags
}

# ===========================================================================
# Security Groups
# ===========================================================================

resource "aws_security_group" "app" {
  name        = "app-${var.project_name}"
  description = "Permite ICMP desde db y vpc-c, trafico saliente"
  vpc_id      = aws_vpc.app.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.db_cidr, var.c_cidr]
    description = "ICMP desde VPCs con peering"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "app-sg-${var.project_name}"
  })
}

resource "aws_security_group" "db" {
  name        = "db-${var.project_name}"
  description = "Permite MySQL desde VPC app, ICMP desde app"
  vpc_id      = aws_vpc.db.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.app_cidr]
    description = "MySQL desde VPC app"
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.app_cidr]
    description = "ICMP desde VPC app"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "db-sg-${var.project_name}"
  })
}

resource "aws_security_group" "c" {
  name        = "c-${var.project_name}"
  description = "Permite ICMP desde app, trafico saliente"
  vpc_id      = aws_vpc.c.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.app_cidr]
    description = "ICMP desde VPC app"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "c-sg-${var.project_name}"
  })
}

# ===========================================================================
# Instancias de test
# ===========================================================================

resource "aws_instance" "test_app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.app_private["private-1"].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.app_private["private-1"].cidr_block, 10)

  # Sin user_data: la AMI AL2023 estandar ya incluye SSM Agent.

  tags = merge(local.common_tags, {
    Name = "test-app-${var.project_name}"
  })

  depends_on = [aws_nat_gateway.app]
}

resource "aws_instance" "test_db" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.db["private-1"].id
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.db["private-1"].cidr_block, 10)

  # Sin user_data: la AMI AL2023 estandar ya incluye SSM Agent.
  # Los VPC Endpoints permiten que el agente se registre sin Internet.

  tags = merge(local.common_tags, {
    Name = "test-db-${var.project_name}"
  })

  depends_on = [aws_vpc_endpoint.db_ssm]
}

resource "aws_instance" "test_c" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.c["private-1"].id
  vpc_security_group_ids = [aws_security_group.c.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.c["private-1"].cidr_block, 10)

  # Sin user_data: la AMI AL2023 estandar ya incluye SSM Agent.
  # Los VPC Endpoints permiten que el agente se registre sin Internet.

  tags = merge(local.common_tags, {
    Name = "test-c-${var.project_name}"
  })

  depends_on = [aws_vpc_endpoint.c_ssm]
}
