# ═══════════════════════════════════════════════════════════════════════════════
# Red — VPC con subredes publicas y privadas en dos AZs
# ═══════════════════════════════════════════════════════════════════════════════
#
# Arquitectura de red:
#
#   VPC: 10.44.0.0/16
#   ├── Subred publica AZ-a  (10.44.0.0/24)  — ALB, NAT Gateway
#   ├── Subred publica AZ-b  (10.44.1.0/24)  — ALB
#   ├── Subred privada AZ-a  (10.44.10.0/24) — Instancias EC2
#   └── Subred privada AZ-b  (10.44.11.0/24) — Instancias EC2
#
# Separacion de responsabilidades:
#   - Subredes PUBLICAS: ALB y NAT Gateway. El ALB necesita IPs publicas para
#     recibir trafico de internet. El NAT Gateway necesita una IP elastica para
#     que las instancias privadas tengan salida a internet.
#   - Subredes PRIVADAS: instancias EC2. No tienen IP publica asignada.
#     Su trafico de salida (actualizaciones de paquetes, agente CodeDeploy,
#     descarga de artefactos de S3) pasa por el NAT Gateway.
#
# NAT Gateway unico (AZ-a):
#   Para un laboratorio se usa un unico NAT Gateway para minimizar costes.
#   En produccion se recomiendan NAT Gateways por AZ para eliminar el SPOF
#   y el trafico inter-AZ. Documentado en "Buenas practicas" del README.

# Filtra las AZs que soportan instancias ARM64 (familia Graviton).
# No todas las AZs de una region ofrecen los tipos t4g/m7g/c7g; este filtro
# garantiza que las subredes se crean solo en AZs donde el tipo de instancia
# configurado en var.instance_type esta disponible.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Obtiene las AZs donde el tipo de instancia tiene capacidad disponible.
# Terraform usara las dos primeras AZs del resultado para las subredes.
data "aws_ec2_instance_type_offerings" "arm64" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

# AZs validas: interseccion entre las AZs disponibles en la region y las que
# soportan el tipo de instancia ARM64 configurado. Se toman las dos primeras
# para las subredes publicas y privadas.
locals {
  arm64_azs = slice(
    [for az in data.aws_availability_zones.available.names :
      az if contains(data.aws_ec2_instance_type_offerings.arm64.locations, az)
    ],
    0, 2
  )
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${var.project}-vpc"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Subredes publicas ─────────────────────────────────────────────────────────
#
# map_public_ip_on_launch = false: el ALB se registra con su IP elastica propia;
# no necesitamos que las subredes asignen IPs publicas automaticamente.
# (Las instancias EC2 van en las privadas y tampoco necesitan IP publica.)

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.arm64_azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.project}-public-${count.index + 1}"
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "public"
  }
}

# ── Subredes privadas ─────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.arm64_azs[count.index]

  tags = {
    Name      = "${var.project}-private-${count.index + 1}"
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "private"
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
#
# Permite el trafico entrante y saliente entre la VPC e internet.
# Solo lo usan las subredes publicas (ALB).

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name      = "${var.project}-igw"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
#
# Permite que las instancias en subredes privadas inicien conexiones salientes
# a internet (actualizaciones, descarga del agente CodeDeploy, llamadas a APIs
# de AWS) sin tener una IP publica propia.
# El NAT Gateway se coloca en la subred publica AZ-a y usa una IP elastica fija.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name      = "${var.project}-nat-eip"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  # El NAT Gateway requiere que el IGW este adjunto a la VPC antes de crearse.
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name      = "${var.project}-nat"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Tablas de rutas ───────────────────────────────────────────────────────────

# Tabla publica: trafico de salida hacia internet a traves del IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name      = "${var.project}-public-rt"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Tabla privada: trafico de salida hacia internet a traves del NAT Gateway.
# El trafico hacia otros recursos dentro de la VPC sigue usando las rutas locales.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name      = "${var.project}-private-rt"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
