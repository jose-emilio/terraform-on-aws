# ── Data sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# AMI mas reciente de Amazon Linux 2023 (ARM64 / Graviton)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Security Groups
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Permite trafico HTTP entrante al ALB desde internet."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Salida irrestricta hacia los Target Groups"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "alb-inbound"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2-sg"
  description = "Permite trafico HTTP desde el ALB a las instancias EC2."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP solo desde el ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida irrestricta (actualizaciones de paquetes, agente CodeDeploy, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "ec2-from-alb"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# ALB — Application Load Balancer con un unico Target Group
# ═══════════════════════════════════════════════════════════════════════════════
#
# En despliegues IN_PLACE solo se necesita un Target Group.
# CodeDeploy deregistra las instancias del lote actual, despliega la nueva
# version y las vuelve a registrar, todo sobre el mismo Target Group.

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "inplace-traffic-control"
  }
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project}-app-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 10

  health_check {
    path                = "/health"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Bucket de artefactos de la aplicacion
# ═══════════════════════════════════════════════════════════════════════════════
#
# Almacena los paquetes zip que CodeDeploy descarga en cada instancia EC2.
# Cada revision es un zip que contiene: appspec.yml, ficheros de la app y scripts.
# La estructura del bucket es: releases/<version>.zip

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codedeploy-app-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "artifacts_bucket_policy" {
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-releases"
    status = "Enabled"

    filter {
      prefix = "releases/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Launch Template y ASG
# ═══════════════════════════════════════════════════════════════════════════════
#
# El Launch Template define la configuracion de cada instancia:
#   - AMI: Amazon Linux 2023
#   - Instance Profile: permisos para leer artefactos de S3 y usar SSM
#   - Security Group: solo acepta trafico HTTP del ALB
#   - IMDSv2: obligatorio (http_tokens = "required") para evitar SSRF
#   - user_data: instala Apache y el agente de CodeDeploy en el arranque
#
# El agente de CodeDeploy es el proceso que se ejecuta en cada instancia EC2
# y recibe las instrucciones del servicio CodeDeploy. Ejecuta los hooks del
# appspec.yml: descarga el artefacto de S3, copia los ficheros y ejecuta los
# scripts de cada fase del ciclo de vida del despliegue.

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    # ── Paso 1: Apache primero ────────────────────────────────────────────────
    # Se instala y arranca Apache antes que nada para que el health check del ALB
    # pase desde el principio. dnf update puede tardar varios minutos y, si se
    # ejecuta antes, las instancias aparecen como Unhealthy durante ese tiempo.
    dnf install -y httpd

    echo "OK" > /var/www/html/health
    echo "<h1>${var.project} — instancia lista</h1>" > /var/www/html/index.html

    systemctl enable httpd
    systemctl start httpd

    # ── Paso 2: Actualizar el sistema ─────────────────────────────────────────
    dnf update -y

    # ── Paso 3: Agente CodeDeploy ─────────────────────────────────────────────
    dnf install -y ruby wget

    cd /tmp
    wget "https://aws-codedeploy-${data.aws_region.current.region}.s3.${data.aws_region.current.region}.amazonaws.com/latest/install"
    chmod +x ./install
    ./install auto

    systemctl enable codedeploy-agent
    systemctl start codedeploy-agent
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Purpose   = "codedeploy-target"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ASG de la aplicacion: CodeDeploy despliega IN_PLACE sobre estas instancias.
# Con MinimumHealthy75Pct despliega en lotes de 1 instancia (25% de 4),
# manteniendo siempre al menos 3 instancias activas bajo el ALB.

resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-app-asg"
  desired_capacity    = var.asg_desired_capacity
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

