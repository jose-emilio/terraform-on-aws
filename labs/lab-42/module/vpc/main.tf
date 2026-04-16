# ═══════════════════════════════════════════════════════════════════════════════
# Modulo VPC — v1.0.0
# ═══════════════════════════════════════════════════════════════════════════════
#
# Crea un VPC con la siguiente estructura de red:
#
#   VPC (var.cidr_block)
#   ├── Internet Gateway
#   ├── Subredes publicas  (map_public_ip_on_launch = true)
#   │   └── Tabla de rutas: 0.0.0.0/0 → Internet Gateway
#   └── Subredes privadas
#       └── Tabla de rutas: sin ruta a internet (preparada para NAT Gateway)
#
# Uso minimo:
#   module "vpc" {
#     source = "https://<endpoint>/generic/<repo>/vpc-module/1.0.0/vpc-module-1.0.0.tar.gz"
#     name   = "mi-vpc"
#   }
#
# Todos los demas parametros tienen valores por defecto funcionales para us-east-1.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(var.tags, { Name = var.name })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

# ── Subredes publicas ─────────────────────────────────────────────────────────
#
# map_public_ip_on_launch = true: las instancias lanzadas en estas subredes
# reciben una IP publica automaticamente, sin necesidad de asignacion manual.
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index % length(var.availability_zones)]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${count.index + 1}"
    Tier = "public"
  })
}

# ── Subredes privadas ─────────────────────────────────────────────────────────
#
# Sin map_public_ip_on_launch — las instancias no tienen IP publica directa.
# Para acceso a internet saliente se necesitaria un NAT Gateway (fuera del
# alcance de esta version del modulo, preparado en v1.1.0).
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${count.index + 1}"
    Tier = "private"
  })
}

# ── Tabla de rutas publica ────────────────────────────────────────────────────
#
# Una sola tabla de rutas compartida por todas las subredes publicas.
# La ruta por defecto (0.0.0.0/0) apunta al Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Tabla de rutas privada ────────────────────────────────────────────────────
#
# Sin rutas de salida a internet por ahora. Las subredes privadas solo tienen
# trafico local (dentro del VPC). Añadir una ruta 0.0.0.0/0 → NAT Gateway
# para acceso saliente a internet es el siguiente paso natural (Reto 1).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
