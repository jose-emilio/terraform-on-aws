# ===========================================================================
# Lab19 — Conectividad Punto a Punto con VPC Peering (LocalStack)
# ===========================================================================
# Nota: LocalStack emula VPC Peering a nivel de API pero no ejecuta trafico
# real. El objetivo es validar la estructura de Terraform.

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
# VPC app
# ===========================================================================

resource "aws_vpc" "app" {
  cidr_block           = var.app_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-app-${var.project_name}"
  })
}

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

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.app.id

  tags = merge(local.common_tags, {
    Name = "app-private-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "app_private" {
  for_each = aws_subnet.app_private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

# ===========================================================================
# VPC db
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
# VPC C
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

resource "aws_route" "app_to_db" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = var.db_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}

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

resource "aws_route" "app_to_c" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = var.c_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_c.id
}

resource "aws_route" "c_to_app" {
  route_table_id            = aws_route_table.c.id
  destination_cidr_block    = var.app_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_c.id
}

# ===========================================================================
# Instancias EC2 de test
# ===========================================================================

resource "aws_instance" "test_app" {
  ami           = "ami-00000000000000000"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.app_private["private-1"].id

  tags = merge(local.common_tags, {
    Name = "test-app-${var.project_name}"
  })
}

resource "aws_instance" "test_db" {
  ami           = "ami-00000000000000000"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.db["private-1"].id

  tags = merge(local.common_tags, {
    Name = "test-db-${var.project_name}"
  })
}

resource "aws_instance" "test_c" {
  ami           = "ami-00000000000000000"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.c["private-1"].id

  tags = merge(local.common_tags, {
    Name = "test-c-${var.project_name}"
  })
}
