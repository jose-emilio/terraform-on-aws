# ===========================================================================
# Lab18 — Seguridad y Control de Trafico en VPC
# ===========================================================================
# Modelo de seguridad por capas: NACL (Capa 4) + Security Groups (Capa 4/7)
# Patron ALB -> EC2 con referencia por Security Group
# VPC Flow Logs para diagnostico de trafico REJECT

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

  subnets = {
    "public-1"  = { az_index = 0, subnet_index = 0, public = true }
    "public-2"  = { az_index = 1, subnet_index = 1, public = true }
    "private-1" = { az_index = 0, subnet_index = 10, public = false }
    "private-2" = { az_index = 1, subnet_index = 11, public = false }
  }

  public_subnets  = { for k, v in local.subnets : k => v if v.public }
  private_subnets = { for k, v in local.subnets : k => v if !v.public }

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

# ===========================================================================
# VPC
# ===========================================================================

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

# --- Tabla de rutas publica ---

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
# NAT Gateway — Salida a Internet para subredes privadas
# ===========================================================================

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-${var.project_name}"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this["public-1"].id

  tags = merge(local.common_tags, {
    Name = "natgw-${var.project_name}"
  })

  depends_on = [aws_internet_gateway.main]
}

# --- Tabla de rutas privada ---

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private.id
}

# ===========================================================================
# Security Group del ALB — Puertos dinamicos desde Internet
# ===========================================================================

resource "aws_security_group" "alb" {
  name        = "alb-${var.project_name}"
  description = "Trafico HTTP/HTTPS desde Internet hacia el ALB"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.alb_ingress_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "Puerto ${ingress.value} desde Internet"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "alb-sg-${var.project_name}"
  })
}

# ===========================================================================
# Security Group de las EC2 — Solo trafico desde el ALB
# ===========================================================================
# Patron clave: security_groups referencia al SG del ALB, no un CIDR.
# Si el ALB cambia de IP, la regla sigue funcionando.

resource "aws_security_group" "app" {
  name        = "app-${var.project_name}"
  description = "Trafico solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "HTTP desde el ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente (actualizaciones, SSM, etc.)"
  }

  tags = merge(local.common_tags, {
    Name = "app-sg-${var.project_name}"
  })
}

# ===========================================================================
# Network ACL — Subred publica (bloqueo de IP maliciosa)
# ===========================================================================
# Las NACLs son stateless: necesitan reglas explicitas para trafico de
# entrada Y salida. Las reglas se evaluan en orden numerico ascendente;
# la primera que coincida se aplica.

resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  # --- Reglas de entrada (ingress) ---

  # Regla 50: Bloquear IP maliciosa (DENY antes de cualquier ALLOW)
  ingress {
    rule_no    = 50
    action     = "deny"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.blocked_ip
  }

  # Regla 100: Permitir HTTP
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"
  }

  # Regla 110: Permitir HTTPS
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"
  }

  # Regla 120: Puertos efimeros (trafico de retorno)
  # Las NACLs son stateless: sin esta regla, las respuestas a conexiones
  # salientes (actualizaciones, NAT, etc.) serian bloqueadas.
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # --- Reglas de salida (egress) ---

  # Regla 100: Permitir todo el trafico saliente
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = merge(local.common_tags, {
    Name = "nacl-public-${var.project_name}"
  })
}

# ===========================================================================
# Network ACL — Subred privada
# ===========================================================================

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if !local.subnets[k].public]

  # --- Reglas de entrada ---

  # Regla 100: Permitir trafico desde la VPC (ALB -> EC2)
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.vpc_cidr
  }

  # Regla 110: Puertos efimeros desde Internet (respuestas a conexiones salientes)
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # --- Reglas de salida ---

  # Regla 100: Permitir todo el trafico saliente
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = merge(local.common_tags, {
    Name = "nacl-private-${var.project_name}"
  })
}

# ===========================================================================
# Application Load Balancer
# ===========================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  tags = merge(local.common_tags, {
    Name = "alb-${var.project_name}"
  })
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 10
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = local.common_tags
}

# ===========================================================================
# Instancias EC2 de aplicacion — Una por AZ en subredes privadas
# ===========================================================================

resource "aws_iam_role" "app" {
  name = "app-instance-role-${var.project_name}"

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
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "app-instance-profile-${var.project_name}"
  role = aws_iam_role.app.name

  tags = local.common_tags
}

resource "aws_instance" "app" {
  for_each = local.private_subnets

  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.this[each.key].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  user_data = file("${path.module}/scripts/app_init.sh")

  tags = merge(local.common_tags, {
    Name = "app-${var.project_name}-${each.key}"
  })

  depends_on = [aws_route.private_nat]
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = local.private_subnets

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[each.key].id
  port             = 80
}

# ===========================================================================
# VPC Flow Logs — Solo trafico REJECT para diagnostico
# ===========================================================================

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.project_name}/flow-logs"
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

resource "aws_flow_log" "reject" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(local.common_tags, {
    Name = "flow-log-reject-${var.project_name}"
  })
}
