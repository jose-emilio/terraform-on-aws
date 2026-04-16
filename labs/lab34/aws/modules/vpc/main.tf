# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.project}-vpc" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.project}-igw" })
}

# ── Subnets publicas ──────────────────────────────────────────────────────────
#
# Alojan un NAT Gateway por AZ. Las instancias EC2 no se despliegan aqui.

resource "aws_subnet" "public" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.project}-public-${each.key}" })
}

# ── Subnets privadas ──────────────────────────────────────────────────────────
#
# Una subnet por AZ. Cada una usa el NAT Gateway de su propia AZ para
# el trafico de salida — sin cruce de AZs, sin costes de transferencia inter-AZ
# y sin punto unico de fallo si una AZ cae.

resource "aws_subnet" "private" {
  for_each          = var.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = merge(var.tags, { Name = "${var.project}-private-${each.key}" })
}

# ── Route table publica ───────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ── NAT Gateways (uno por AZ) ─────────────────────────────────────────────────
#
# Un NAT Gateway por AZ garantiza que cada subnet privada tenga salida a
# internet sin cruzar AZs. Si una AZ falla, las instancias de las otras AZs
# siguen teniendo salida a traves de su propio NAT Gateway.
# Cada NAT Gateway requiere una Elastic IP propia.

resource "aws_eip" "nat" {
  for_each = var.public_subnets
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.project}-nat-eip-${each.key}" })
}

resource "aws_nat_gateway" "main" {
  for_each      = aws_subnet.public
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(var.tags, { Name = "${var.project}-nat-${each.key}" })
}

# ── Route tables privadas ─────────────────────────────────────────────────────
#
# Cada subnet privada enruta el trafico de salida al NAT Gateway de su AZ.

resource "aws_route_table" "private" {
  for_each = var.private_subnets
  vpc_id   = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }

  tags = merge(var.tags, { Name = "${var.project}-private-rt-${each.key}" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
