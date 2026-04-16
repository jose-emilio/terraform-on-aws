# ===========================================================================
# Lab20 — Hub-and-Spoke con Transit Gateway y RAM
# ===========================================================================
# Topologia con inspeccion centralizada:
#
#   client-a (10.16.0.0/16) ──┐
#                              ├── TGW ── inspection (10.17.0.0/16) ── TGW ── egress (10.18.0.0/16) ── Internet
#   client-b (10.19.0.0/16) ──┘            (Appliance Mode)                   (IGW + NAT GW)
#
# Tablas de rutas del TGW:
#   - client-rt:      0.0.0.0/0 → inspection (todo pasa por inspeccion)
#   - inspection-rt:  0.0.0.0/0 → egress + rutas propagadas de clients
#   - egress-rt:      rutas propagadas de clients + inspection
#
# RAM comparte el TGW con una cuenta de aplicacion simulada.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ami" "al2023" {
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
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

# ===========================================================================
# VPC client-a
# ===========================================================================

resource "aws_vpc" "client_a" {
  cidr_block           = var.client_a_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-client-a-${var.project_name}"
  })
}

resource "aws_subnet" "client_a" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.client_a.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.client_a.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "client-a-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "client_a" {
  vpc_id = aws_vpc.client_a.id

  tags = merge(local.common_tags, {
    Name = "client-a-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "client_a" {
  for_each = aws_subnet.client_a

  subnet_id      = each.value.id
  route_table_id = aws_route_table.client_a.id
}

# ===========================================================================
# VPC client-b
# ===========================================================================

resource "aws_vpc" "client_b" {
  cidr_block           = var.client_b_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-client-b-${var.project_name}"
  })
}

resource "aws_subnet" "client_b" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.client_b.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.client_b.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "client-b-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "client_b" {
  vpc_id = aws_vpc.client_b.id

  tags = merge(local.common_tags, {
    Name = "client-b-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "client_b" {
  for_each = aws_subnet.client_b

  subnet_id      = each.value.id
  route_table_id = aws_route_table.client_b.id
}

# ===========================================================================
# VPC inspection — Todo el trafico inter-VPC y a Internet pasa por aqui
# ===========================================================================

resource "aws_vpc" "inspection" {
  cidr_block           = var.inspection_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-inspection-${var.project_name}"
  })
}

resource "aws_subnet" "inspection" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.inspection.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.inspection.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "inspection-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "inspection" {
  vpc_id = aws_vpc.inspection.id

  tags = merge(local.common_tags, {
    Name = "inspection-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "inspection" {
  for_each = aws_subnet.inspection

  subnet_id      = each.value.id
  route_table_id = aws_route_table.inspection.id
}

# ===========================================================================
# VPC egress — Salida centralizada a Internet (IGW + NAT Gateway)
# ===========================================================================

resource "aws_vpc" "egress" {
  cidr_block           = var.egress_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-egress-${var.project_name}"
  })
}

# --- Subredes publicas (IGW) ---

resource "aws_subnet" "egress_public" {
  for_each = { for idx, az in local.azs : "public-${idx + 1}" => { az = az, index = idx } }

  vpc_id                  = aws_vpc.egress.id
  availability_zone       = each.value.az
  cidr_block              = cidrsubnet(aws_vpc.egress.cidr_block, 8, each.value.index)
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "egress-${each.key}-${var.project_name}"
    Tier = "public"
  })
}

# --- Subredes privadas (TGW attachment) ---

resource "aws_subnet" "egress_private" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.egress.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.egress.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "egress-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id

  tags = merge(local.common_tags, {
    Name = "igw-egress-${var.project_name}"
  })
}

# --- Tabla de rutas publica ---

resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id

  tags = merge(local.common_tags, {
    Name = "egress-public-rt-${var.project_name}"
  })
}

resource "aws_route" "egress_public_internet" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

resource "aws_route_table_association" "egress_public" {
  for_each = aws_subnet.egress_public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.egress_public.id
}

# Rutas de retorno en la tabla publica: el NAT GW necesita saber como
# devolver trafico a las otras VPCs via TGW.
resource "aws_route" "egress_public_to_clients" {
  for_each = tomap({
    client_a   = var.client_a_cidr
    client_b   = var.client_b_cidr
    inspection = var.inspection_cidr
  })

  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

# --- NAT Gateway — Uno por AZ para alta disponibilidad ---

resource "aws_eip" "nat_egress" {
  for_each = aws_subnet.egress_public

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-egress-${each.key}-${var.project_name}"
  })
}

resource "aws_nat_gateway" "egress" {
  for_each = aws_subnet.egress_public

  allocation_id = aws_eip.nat_egress[each.key].id
  subnet_id     = each.value.id

  tags = merge(local.common_tags, {
    Name = "natgw-egress-${each.key}-${var.project_name}"
  })

  depends_on = [aws_internet_gateway.egress]
}

# --- Tablas de rutas privadas — Una por AZ, cada una apunta a su NAT local ---

resource "aws_route_table" "egress_private" {
  for_each = aws_subnet.egress_private

  vpc_id = aws_vpc.egress.id

  tags = merge(local.common_tags, {
    Name = "egress-private-rt-${each.key}-${var.project_name}"
  })
}

resource "aws_route" "egress_private_nat" {
  for_each = aws_subnet.egress_private

  route_table_id         = aws_route_table.egress_private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # Cada subred privada sale por el NAT Gateway de su misma AZ
  nat_gateway_id         = aws_nat_gateway.egress["public-${split("-", each.key)[1]}"].id
}

# Rutas de retorno en cada tabla privada: trafico hacia las otras VPCs via TGW
resource "aws_route" "egress_private_to_clients" {
  for_each = {
    for pair in setproduct(keys(aws_subnet.egress_private), keys(tomap({
      client_a   = var.client_a_cidr
      client_b   = var.client_b_cidr
      inspection = var.inspection_cidr
    }))) : "${pair[0]}-${pair[1]}" => {
      subnet_key = pair[0]
      cidr = tomap({
        client_a   = var.client_a_cidr
        client_b   = var.client_b_cidr
        inspection = var.inspection_cidr
      })[pair[1]]
    }
  }

  route_table_id         = aws_route_table.egress_private[each.value.subnet_key].id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_private" {
  for_each = aws_subnet.egress_private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.egress_private[each.key].id
}

# ===========================================================================
# Transit Gateway — Hub central
# ===========================================================================

resource "aws_ec2_transit_gateway" "main" {
  description                     = "TGW central - Hub-and-Spoke Lab20"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "enable"

  tags = merge(local.common_tags, {
    Name = "tgw-${var.project_name}"
  })
}

# ===========================================================================
# TGW Attachments — Conectar las 4 VPCs al hub
# ===========================================================================

resource "aws_ec2_transit_gateway_vpc_attachment" "client_a" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.client_a.id
  subnet_ids         = [for k, s in aws_subnet.client_a : s.id]

  tags = merge(local.common_tags, {
    Name = "tgw-att-client-a-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "client_b" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.client_b.id
  subnet_ids         = [for k, s in aws_subnet.client_b : s.id]

  tags = merge(local.common_tags, {
    Name = "tgw-att-client-b-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.inspection.id
  subnet_ids         = [for k, s in aws_subnet.inspection : s.id]

  # Appliance Mode: garantiza simetria de trafico (ida y vuelta por la misma AZ).
  # Esencial para firewalls stateful de terceros (Palo Alto, Fortinet, etc.).
  appliance_mode_support = var.enable_appliance_mode ? "enable" : "disable"

  tags = merge(local.common_tags, {
    Name = "tgw-att-inspection-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [for k, s in aws_subnet.egress_private : s.id]

  tags = merge(local.common_tags, {
    Name = "tgw-att-egress-${var.project_name}"
  })
}

# ===========================================================================
# TGW Route Tables — Segmentacion de trafico por inspeccion
# ===========================================================================
# client-rt:      todo el trafico (0.0.0.0/0) va a inspection
# inspection-rt:  Internet (0.0.0.0/0) va a egress + rutas de vuelta a clients
# egress-rt:      rutas de vuelta a clients e inspection

# --- Tabla de clientes ---

resource "aws_ec2_transit_gateway_route_table" "client" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = merge(local.common_tags, {
    Name = "tgw-rt-client-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "client_a" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_a.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.client.id
}

resource "aws_ec2_transit_gateway_route_table_association" "client_b" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_b.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.client.id
}

# Todo el trafico de los clients pasa por inspection
resource "aws_ec2_transit_gateway_route" "client_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.client.id
}

# --- Tabla de inspeccion ---

resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = merge(local.common_tags, {
    Name = "tgw-rt-inspection-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# Internet sale por egress
resource "aws_ec2_transit_gateway_route" "inspection_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# Rutas de vuelta a los clients (propagadas)
resource "aws_ec2_transit_gateway_route_table_propagation" "client_a_to_inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_a.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "client_b_to_inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_b.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# --- Tabla de egress ---

resource "aws_ec2_transit_gateway_route_table" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = merge(local.common_tags, {
    Name = "tgw-rt-egress-${var.project_name}"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

# Rutas de vuelta a clients e inspection (propagadas)
resource "aws_ec2_transit_gateway_route_table_propagation" "client_a_to_egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_a.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "client_b_to_egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_b.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "inspection_to_egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

# ===========================================================================
# Rutas en las VPCs — Todo el trafico no local va al TGW
# ===========================================================================

# Clients: 0.0.0.0/0 → TGW (el TGW lo envia a inspection)
resource "aws_route" "client_a_default" {
  route_table_id         = aws_route_table.client_a.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.client_a]
}

resource "aws_route" "client_b_default" {
  route_table_id         = aws_route_table.client_b.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.client_b]
}

# Inspection: 0.0.0.0/0 → TGW (el TGW lo envia a egress)
resource "aws_route" "inspection_default" {
  route_table_id         = aws_route_table.inspection.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

# ===========================================================================
# AWS RAM — Compartir el TGW con una cuenta de aplicacion
# ===========================================================================

resource "aws_ram_resource_share" "tgw" {
  name                      = "tgw-share-${var.project_name}"
  allow_external_principals = true

  tags = merge(local.common_tags, {
    Name = "ram-tgw-share-${var.project_name}"
  })
}

resource "aws_ram_resource_association" "tgw" {
  resource_share_arn = aws_ram_resource_share.tgw.arn
  resource_arn       = aws_ec2_transit_gateway.main.arn
}

resource "aws_ram_principal_association" "app_account" {
  resource_share_arn = aws_ram_resource_share.tgw.arn
  principal          = var.app_account_id
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
# VPC Flow Logs — Verificar que el trafico pasa por inspection
# ===========================================================================
# Se habilitan Flow Logs en la inspection-vpc para demostrar que todo el
# trafico inter-VPC y a Internet atraviesa esta VPC. Si un paquete entre
# client-a y client-b aparece en los flow logs de inspection, confirma
# que la segmentacion del TGW funciona correctamente.

resource "aws_cloudwatch_log_group" "inspection_flow_logs" {
  name              = "/vpc/${var.project_name}/inspection-flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  name = "vpc-flow-logs-${var.project_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "vpc-flow-logs-${var.project_name}"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "inspection" {
  vpc_id               = aws_vpc.inspection.id
  traffic_type         = "ALL"
  max_aggregation_interval = 60
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.inspection_flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(local.common_tags, {
    Name = "flow-log-inspection-${var.project_name}"
  })
}

# ===========================================================================
# Security Groups para instancias de test
# ===========================================================================

resource "aws_security_group" "test_client_a" {
  name        = "test-client-a-${var.project_name}"
  description = "Permite ICMP desde otras VPCs y trafico saliente"
  vpc_id      = aws_vpc.client_a.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.client_b_cidr, var.inspection_cidr, var.egress_cidr]
    description = "ICMP desde otras VPCs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "test-client-a-sg-${var.project_name}"
  })
}

resource "aws_security_group" "test_client_b" {
  name        = "test-client-b-${var.project_name}"
  description = "Permite ICMP desde otras VPCs y trafico saliente"
  vpc_id      = aws_vpc.client_b.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.client_a_cidr, var.inspection_cidr, var.egress_cidr]
    description = "ICMP desde otras VPCs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "test-client-b-sg-${var.project_name}"
  })
}

# ===========================================================================
# Instancias de test — Verifican conectividad inter-VPC via TGW
# ===========================================================================

resource "aws_instance" "test_client_a" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.client_a["private-1"].id
  vpc_security_group_ids = [aws_security_group.test_client_a.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.client_a["private-1"].cidr_block, 10)

  user_data = file("${path.module}/scripts/test_init.sh")

  tags = merge(local.common_tags, {
    Name = "test-client-a-${var.project_name}"
  })

  depends_on = [
    aws_route.client_a_default,
    aws_ec2_transit_gateway_route.client_default,
    aws_ec2_transit_gateway_route.inspection_default,
    aws_nat_gateway.egress,
  ]
}

resource "aws_instance" "test_client_b" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.client_b["private-1"].id
  vpc_security_group_ids = [aws_security_group.test_client_b.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.client_b["private-1"].cidr_block, 10)

  user_data = file("${path.module}/scripts/test_init.sh")

  tags = merge(local.common_tags, {
    Name = "test-client-b-${var.project_name}"
  })

  depends_on = [
    aws_route.client_b_default,
    aws_ec2_transit_gateway_route.client_default,
    aws_ec2_transit_gateway_route.inspection_default,
    aws_nat_gateway.egress,
  ]
}
