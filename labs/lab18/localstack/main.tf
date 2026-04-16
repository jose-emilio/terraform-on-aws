# ===========================================================================
# Lab18 — Seguridad y Control de Trafico en VPC (LocalStack)
# ===========================================================================
# Nota: LocalStack emula la mayoria de recursos de red (VPC, subnets, SGs,
# NACLs, ALB, Flow Logs) pero no ejecuta trafico real. El objetivo de esta
# version es validar la estructura de Terraform y el plan de despliegue
# sin incurrir en costes de AWS.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"
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
# NAT Gateway
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
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "app-sg-${var.project_name}"
  })
}

# ===========================================================================
# Network ACL — Subred publica (bloqueo de IP maliciosa)
# ===========================================================================

resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  # Regla 50: Bloquear IP maliciosa
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
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # Regla de salida: Permitir todo
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

  # Regla 100: Permitir trafico desde la VPC
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.vpc_cidr
  }

  # Regla 110: Puertos efimeros desde Internet
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # Regla de salida: Permitir todo
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
# Application Load Balancer — No disponible en LocalStack Community
# ===========================================================================
# ELBv2 (ALB) requiere licencia de pago en LocalStack.
# Descomenta los siguientes bloques si dispones de una cuenta Pro.

# resource "aws_lb" "main" {
#   name               = "${var.project_name}-alb"
#   internal           = false
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.alb.id]
#   subnets            = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]
#
#   tags = merge(local.common_tags, {
#     Name = "alb-${var.project_name}"
#   })
# }

# resource "aws_lb_target_group" "app" {
#   name     = "${var.project_name}-tg"
#   port     = 80
#   protocol = "HTTP"
#   vpc_id   = aws_vpc.main.id
#
#   health_check {
#     path                = "/"
#     protocol            = "HTTP"
#     healthy_threshold   = 2
#     unhealthy_threshold = 3
#     timeout             = 5
#     interval            = 10
#   }
#
#   tags = local.common_tags
# }

# resource "aws_lb_listener" "http" {
#   load_balancer_arn = aws_lb.main.arn
#   port              = 80
#   protocol          = "HTTP"
#
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.app.arn
#   }
#
#   tags = local.common_tags
# }

# ===========================================================================
# Instancias EC2 de aplicacion
# ===========================================================================

resource "aws_instance" "app" {
  for_each = local.private_subnets

  ami                    = "ami-00000000000000000" # AMI ficticia para LocalStack
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.this[each.key].id
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = merge(local.common_tags, {
    Name = "app-${var.project_name}-${each.key}"
  })

  depends_on = [aws_route.private_nat]
}

# Descomenta si dispones de LocalStack Pro (ELBv2):
# resource "aws_lb_target_group_attachment" "app" {
#   for_each = local.private_subnets
#
#   target_group_arn = aws_lb_target_group.app.arn
#   target_id        = aws_instance.app[each.key].id
#   port             = 80
# }

# ===========================================================================
# VPC Flow Logs — Solo trafico REJECT
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
