# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.32.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.project}-vpc" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-igw" })
}

# ── Subnets publicas (EC2) ────────────────────────────────────────────────────
#
# La instancia EC2 se despliega en una subnet publica para acceso directo.
# map_public_ip_on_launch = true asigna IP publica automaticamente al arrancar,
# sin necesidad de EIP ni NAT Gateway, lo que reduce costes en este laboratorio.

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.project}-public-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ── Subnets privadas (ElastiCache) ────────────────────────────────────────────
#
# ElastiCache requiere subnets en al menos dos AZs distintas.
# Las subnets privadas no tienen ruta a internet: solo permiten trafico
# interno de la VPC (EC2 → Redis a traves del routing local de la VPC).

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = merge(local.tags, { Name = "${var.project}-private-${each.key}" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ── Security Group: EC2 ───────────────────────────────────────────────────────

resource "aws_security_group" "app" {
  name        = "${var.project}-app"
  description = "Trafico HTTP publico y salida hacia AWS APIs y Redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-app" })
}

# ── Security Group: Redis ─────────────────────────────────────────────────────
#
# Solo se permite el puerto Redis (6379) desde el Security Group de la EC2.
# Con transit_encryption_enabled = true, ElastiCache exige TLS en todas
# las conexiones; el AUTH token añade una capa de autenticacion adicional.

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis"
  description = "Permite Redis TCP 6379 (TLS) solo desde la instancia de aplicacion"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis TLS desde la instancia de aplicacion"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-redis" })
}
