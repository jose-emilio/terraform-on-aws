# ── Datos ─────────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"

  # Excluye Local Zones y Wavelength Zones: estas zonas requieren opt-in
  # explícito y no soportan todos los servicios (NAT Gateway entre ellos).
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
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# ── Red ───────────────────────────────────────────────────────────────────────

locals {
  # Limita a 2 AZs para controlar el coste del laboratorio
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  public_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 11)]

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.project}-vpc" })
}

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Las instancias del ALB necesitan IPs públicas; las instancias del ASG no.
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${var.project}-public-${local.azs[count.index]}" })
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.project}-private-${local.azs[count.index]}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-igw" })
}

# Un EIP y un NAT Gateway por AZ para que un fallo de zona no corte
# la conectividad de salida de las instancias privadas de las demás AZs.
resource "aws_eip" "nat" {
  count      = length(local.azs)
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.tags, { Name = "${var.project}-nat-eip-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "main" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.tags, { Name = "${var.project}-nat-${local.azs[count.index]}" })
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
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Una route table privada por AZ, cada una apuntando a su propio NAT Gateway.
resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.tags, { Name = "${var.project}-private-rt-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── Seguridad ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Permite trafico HTTP desde Internet al ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-alb-sg" })
}

resource "aws_security_group" "instances" {
  name        = "${var.project}-instances-sg"
  description = "Permite trafico al puerto 8080 solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Puerto de aplicacion desde el ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-instances-sg" })
}

# ── Balanceo de Carga (L7) ────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = merge(local.tags, { Name = "${var.project}-alb" })
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Reduce el tiempo de drenaje al mínimo razonable para el laboratorio.
  # En producción, ajustar según la duración máxima de las peticiones en curso.
  deregistration_delay = 30

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = "${var.project}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ── IAM (SSM) ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ssm" {
  name = "${var.project}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-ssm-role" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ssm-profile"
  role = aws_iam_role.ssm.name

  tags = merge(local.tags, { Name = "${var.project}-ssm-profile" })
}

# ── Flota de Cómputo ──────────────────────────────────────────────────────────

resource "aws_launch_template" "web" {
  name_prefix   = "${var.project}-web-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ssm.name
  }

  # Las instancias viven en subredes privadas; no necesitan IP pública.
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instances.id]
  }

  # templatefile() lee user_data.sh e interpola ${app_version};
  # las variables bash ($TOKEN, $AZ, $ID) no usan llaves y no son afectadas.
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    app_version = var.app_version
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.project}-web" })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${var.project}-launch-template" })
}

resource "aws_autoscaling_group" "web" {
  name = "${var.project}-asg"

  # Distribuye instancias entre todas las subredes privadas disponibles
  vpc_zone_identifier = aws_subnet.private[*].id

  # Apunta siempre a la última versión del Launch Template.
  # Al cambiar la versión, el campo `version` cambia y Terraform activa el instance_refresh.
  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 60

  # Publica métricas del ASG en CloudWatch cada minuto. Sin esto, el Target
  # Tracking solo dispone de las métricas de instancia individuales (EC2),
  # que tienen granularidad de 5 minutos en el tier gratuito.
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # Reemplaza instancias de forma gradual cuando cambia el Launch Template,
  # manteniendo al menos el 90% de la capacidad deseada en todo momento.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 60
    }
    triggers = ["launch_template"]
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-web"
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.project}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    # El ASG añade o elimina instancias para mantener la CPU media en torno al 50%
    target_value = 50.0
  }
}
