# ═══════════════════════════════════════════════════════════════════════════════
# Locals — Zonas de disponibilidad del laboratorio
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  azs = ["${var.region}a", "${var.region}b"]
}

# ═══════════════════════════════════════════════════════════════════════════════
# VPC — Red privada virtual del laboratorio
# ═══════════════════════════════════════════════════════════════════════════════
#
# enable_dns_hostnames = true es necesario para que las instancias EC2 reciban
# nombres DNS públicos (ec2-X-X-X-X.compute-1.amazonaws.com). Sin esto, SSM
# Session Manager no puede resolver el endpoint del servicio desde la instancia.
#
# enable_dns_support = true activa el servidor DNS de Amazon (169.254.169.253)
# dentro de la VPC. Es un requisito para que funcionen los DNS hostnames y los
# VPC Endpoints de tipo Interface.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project}-vpc", Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Internet Gateway — Puerta de salida a internet para las subredes públicas
# ═══════════════════════════════════════════════════════════════════════════════
#
# El IGW realiza NAT estático (1:1) para las instancias con IP pública: traduce
# la IP privada de la ENI a la Elastic IP o IP pública asignada. Sin el IGW,
# las subredes públicas no tienen acceso a internet aunque tengan IP pública.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw", Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subredes públicas — Una por AZ, con IP pública automática
# ═══════════════════════════════════════════════════════════════════════════════
#
# map_public_ip_on_launch = true asigna automáticamente una IP pública a cada
# instancia EC2 lanzada en estas subredes, sin necesidad de crear una Elastic IP.
# Las IPs públicas automáticas no son estáticas: cambian al detener/iniciar la instancia.
#
# Rangos (usando cidrsubnet con newbits=8):
#   AZ-a: 10.47.0.0/24  (índice 0)
#   AZ-b: 10.47.1.0/24  (índice 1)

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name      = "${var.project}-public-${local.azs[count.index]}"
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "public"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subredes privadas — Una por AZ, sin ruta a internet
# ═══════════════════════════════════════════════════════════════════════════════
#
# Las subredes privadas no tienen ruta de salida a internet en este laboratorio
# (no hay NAT Gateway). Su propósito es ilustrar la separación de capas en una
# arquitectura multi-AZ. En producción, un NAT Gateway en cada subred pública
# daría salida a internet a las subredes privadas.
#
# Rangos:
#   AZ-a: 10.47.10.0/24  (índice 10)
#   AZ-b: 10.47.11.0/24  (índice 11)

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name      = "${var.project}-private-${local.azs[count.index]}"
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "private"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tabla de rutas pública — Ruta por defecto hacia el IGW
# ═══════════════════════════════════════════════════════════════════════════════
#
# Una única tabla de rutas sirve a las dos subredes públicas. La ruta 0.0.0.0/0
# → IGW es lo que hace que una subred sea "pública": cualquier tráfico destinado
# a una IP externa sale por el IGW.
#
# Las rutas locales (10.47.0.0/16 → local) se añaden implícitamente por AWS
# y permiten la comunicación entre todas las subredes de la VPC sin configuración
# adicional.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-public", Project = var.project, ManagedBy = "terraform" }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
