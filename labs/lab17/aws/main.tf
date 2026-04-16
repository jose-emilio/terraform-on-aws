# ===========================================================================
# Lab17 — Optimización de Salida a Internet y "NAT Tax"
# ===========================================================================

# --- Data Sources ---

# Obtener las AZs que soportan instancias t4g (Graviton ARM).
# Las AZs que soportan instancias modernas también soportan NAT Gateways;
# las que no (ej: us-east-1e) suelen tener soporte limitado de servicios.
data "aws_ec2_instance_type_offerings" "t4g" {
  filter {
    name   = "instance-type"
    values = ["t4g.small"]
  }
  location_type = "availability-zone-id"
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  # Solo AZs que soportan t4g.small (proxy fiable para soporte de NAT Gateway)
  filter {
    name   = "zone-id"
    values = data.aws_ec2_instance_type_offerings.t4g.locations
  }
}

# AMI de Amazon Linux 2023 ARM para la Instancia NAT (solo se usa si use_nat_instance = true)
data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-arm64"]
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
# Internet Gateway — Comunicación bidireccional para subredes públicas
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
# NAT Gateway × 3 (producción) — Uno por AZ para alta disponibilidad
# ===========================================================================
# Coste: ~$32/mes × 3 = ~$96/mes base + $0.045/GB procesado
# Ventaja: si cae una AZ, las subredes privadas de las otras 2 siguen con salida.
# Sin tráfico cross-AZ: cada subred privada sale por el NAT de su propia AZ.

resource "aws_eip" "nat" {
  for_each = var.use_nat_instance ? toset([]) : toset(local.azs)
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-${var.project_name}-${each.key}"
  })
}

resource "aws_nat_gateway" "this" {
  for_each = var.use_nat_instance ? {} : {
    for idx, az in local.azs : az => "public-${idx + 1}"
  }

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.value].id

  tags = merge(local.common_tags, {
    Name = "natgw-${var.project_name}-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ===========================================================================
# Instancia NAT × 3 (desarrollo) — EC2 t4g.small ARM, una por AZ
# ===========================================================================
# Coste: ~$12.26/mes × 3 = ~$36.78/mes — ahorro ~62% vs NAT Gateway × 3
# Ventaja ARM: mejor relación precio/rendimiento que x86 equivalente
# Limitación: mantenimiento manual (parches, iptables), sin escalado automático

resource "aws_security_group" "nat" {
  count = var.use_nat_instance ? 1 : 0

  name        = "nat-instance-${var.project_name}"
  description = "Permite trafico de las subredes privadas hacia Internet via NAT Instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [for k, s in aws_subnet.this : s.cidr_block if !local.subnets[k].public]
    description = "Todo el trafico desde subredes privadas"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "nat-instance-sg-${var.project_name}"
  })
}

resource "aws_instance" "nat" {
  for_each = var.use_nat_instance ? {
    for idx, az in local.azs : az => "public-${idx + 1}"
  } : {}

  ami                    = data.aws_ami.nat.id
  instance_type          = "t4g.small"
  subnet_id              = aws_subnet.this[each.value].id
  vpc_security_group_ids = [aws_security_group.nat[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  # CLAVE: Desactivar la verificación de origen/destino.
  # Por defecto, EC2 descarta tráfico cuyo origen o destino no sea la propia instancia.
  # Una instancia NAT DEBE reenviar tráfico de otros orígenes, por lo que esta
  # verificación debe estar deshabilitada.
  source_dest_check = false

  # Configurar iptables para NAT al arrancar la instancia.
  # AL2023 minimal no trae NAT preconfigurado (a diferencia de las antiguas AMIs
  # amzn-ami-vpc-nat), por lo que hay que habilitar IP forwarding y crear la
  # regla MASQUERADE manualmente.
  user_data = templatefile("${path.module}/scripts/nat_init.sh", {
    vpc_cidr = var.vpc_cidr
  })

  tags = merge(local.common_tags, {
    Name = "nat-instance-${var.project_name}-${each.key}"
  })
}

# ===========================================================================
# Tablas de rutas privadas — Una por AZ, cada una apunta a su NAT local
# ===========================================================================
# Esto garantiza que el tráfico de cada subred privada sale por el NAT de su
# misma AZ, evitando tráfico cross-AZ y manteniendo la resiliencia.

resource "aws_route_table" "private" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt-${each.key}"
  })
}

# Ruta por defecto: NAT Gateway (producción)
resource "aws_route" "private_nat_gateway" {
  for_each = var.use_nat_instance ? toset([]) : toset(local.azs)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}

# Ruta por defecto: Instancia NAT (desarrollo)
resource "aws_route" "private_nat_instance" {
  for_each = var.use_nat_instance ? toset(local.azs) : toset([])

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id
}

# Cada subred privada se asocia a la tabla de rutas de su propia AZ
resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[local.azs[each.value.az_index]].id
}

# ===========================================================================
# VPC Gateway Endpoint para S3 — Tráfico gratuito, sin pasar por NAT
# ===========================================================================
# El tráfico hacia S3 viaja por la red interna de AWS en lugar de salir por
# el NAT Gateway. Esto elimina el cargo de $0.045/GB que cobra el NAT por
# cada GB procesado. El Gateway Endpoint es completamente gratuito.

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
# IAM Role SSM — Compartido por la instancia NAT y la instancia de test
# ===========================================================================
# Permite administrar ambas instancias via SSM Session Manager sin necesidad
# de abrir puertos SSH ni gestionar claves.

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

resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "ssm-instance-profile-${var.project_name}"
  role = aws_iam_role.ssm.name

  tags = local.common_tags
}

# ===========================================================================
# Instancia de test — Verifica la conectividad NAT desde una subred privada
# ===========================================================================
# Se conecta vía SSM Session Manager (no necesita IP pública ni SSH).
# SSM funciona porque el agente sale a Internet a través del NAT.

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
  ami                    = data.aws_ami.nat.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.this["private-1"].id
  vpc_security_group_ids = [aws_security_group.test.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  # Instalar SSM Agent (AL2023 minimal no lo incluye)
  user_data = file("${path.module}/scripts/test_init.sh")

  tags = merge(local.common_tags, {
    Name = "test-instance-${var.project_name}"
  })

  depends_on = [
    aws_route.private_nat_gateway,
    aws_route.private_nat_instance,
  ]
}
