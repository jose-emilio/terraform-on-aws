# ===========================================================================
# Lab21 — Zonas Hospedadas Privadas y Resolucion DNS
# ===========================================================================
# Zona Hospedada Privada app.internal con:
#   - web.app.internal → ALB (registro Alias)
#   - db.app.internal  → IP privada EC2 (registro A)
# Instancia de test para verificar resolucion con nslookup/dig.

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# AMI Amazon Linux 2023 estandar (incluye SSM Agent + nslookup/dig)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
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

# --- Subredes publicas ---

resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : "public-${idx + 1}" => { az = az, index = idx } }

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.index)
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${each.key}"
    Tier = "public"
  })
}

# --- Subredes privadas ---

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${each.key}"
    Tier = "private"
  })
}

# --- Internet Gateway ---

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
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateway ---

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-${var.project_name}"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["public-1"].id

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
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ===========================================================================
# IAM Role SSM
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
# Security Groups
# ===========================================================================

resource "aws_security_group" "alb" {
  name        = "alb-${var.project_name}"
  description = "HTTP desde la VPC (trafico interno)"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTP desde la VPC"
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

resource "aws_security_group" "web" {
  name        = "web-${var.project_name}"
  description = "HTTP desde el ALB, ICMP desde la VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "HTTP desde el ALB"
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
    description = "ICMP desde la VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "web-sg-${var.project_name}"
  })
}

resource "aws_security_group" "db" {
  name        = "db-${var.project_name}"
  description = "MySQL desde la VPC, ICMP desde la VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "MySQL desde la VPC"
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
    description = "ICMP desde la VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "db-sg-${var.project_name}"
  })
}

resource "aws_security_group" "test" {
  name        = "test-${var.project_name}"
  description = "Solo trafico saliente (test con nslookup/dig)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "test-sg-${var.project_name}"
  })
}

# ===========================================================================
# Application Load Balancer (interno)
# ===========================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for k, s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "alb-${var.project_name}"
  })
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-web-tg"
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
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = local.common_tags
}

# ===========================================================================
# Instancias EC2
# ===========================================================================

# Instancia web (servidor HTTP detras del ALB)
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.private["private-1"].id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y httpd
    INSTANCE_ID=$(ec2-metadata -i | cut -d' ' -f2)
    echo "<h1>Lab21 — web.${var.internal_domain}</h1><p>Instancia: $INSTANCE_ID</p>" > /var/www/html/index.html
    systemctl enable httpd && systemctl start httpd
  EOT

  tags = merge(local.common_tags, {
    Name = "web-${var.project_name}"
  })

  depends_on = [aws_nat_gateway.main]
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

# Instancia db (simula una base de datos con IP privada fija)
resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.private["private-1"].id
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.private["private-1"].cidr_block, 10)

  tags = merge(local.common_tags, {
    Name = "db-${var.project_name}"
  })

  depends_on = [aws_nat_gateway.main]
}

# Instancia de test (para verificar DNS con nslookup/dig)
resource "aws_instance" "test" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.private["private-2"].id
  vpc_security_group_ids = [aws_security_group.test.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y bind-utils
  EOT

  tags = merge(local.common_tags, {
    Name = "test-${var.project_name}"
  })

  depends_on = [aws_nat_gateway.main]
}

# ===========================================================================
# Route 53 — Zona Hospedada Privada
# ===========================================================================

resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "phz-${var.internal_domain}-${var.project_name}"
  })
}

# --- Registro Alias: web.app.internal → ALB ---
resource "aws_route53_record" "web" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "web.${var.internal_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# --- Registro A: db.app.internal → IP privada fija ---
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.db.private_ip]
}
