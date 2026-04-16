# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# KMS — Clave de cifrado para los logs de CloudWatch
# ═══════════════════════════════════════════════════════════════════════════════
#
# CloudWatch Logs requiere que la clave KMS otorgue permisos explícitos al
# servicio logs.<region>.amazonaws.com. Sin el statement AllowCloudWatchLogs,
# el log group se crea pero falla al intentar escribir entradas cifradas.
# La condición kms:EncryptionContext:aws:logs:arn limita el acceso a los
# log groups de esta cuenta, evitando que otras cuentas usen la clave.

resource "aws_kms_key" "logs" {
  description             = "CMK para cifrar el log group de la aplicacion ${var.project}."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "cloudwatch-logs-encryption"
  }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.project}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para la instancia EC2
# ═══════════════════════════════════════════════════════════════════════════════
#
# La instancia necesita dos políticas gestionadas:
#   AmazonSSMManagedInstanceCore  → acceso via SSM Session Manager (sin SSH)
#   CloudWatchAgentServerPolicy   → el agente puede escribir logs y métricas

resource "aws_iam_role" "app" {
  name        = "${var.project}-app-role"
  description = "Rol para la instancia EC2 del laboratorio ${var.project}."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.app.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# Security Group — Sin SSH; acceso solo via SSM
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "SG para la instancia EC2 del lab ${var.project}. Sin ingress: acceso via SSM."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Salida a Internet para dnf, SSM y CloudWatch."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# EC2 — Instancia que genera logs de aplicacion
# ═══════════════════════════════════════════════════════════════════════════════
#
# El user_data realiza tres acciones al arrancar:
#   1. Instala el CloudWatch Agent (dnf)
#   2. Lo configura para leer /var/log/app.log y enviarlo al log group
#   3. Crea e inicia un servicio systemd (log-gen) que escribe entradas
#      INFO/WARN/ERROR aleatorias en /var/log/app.log cada 1-10 segundos
#
# El ratio aproximado de niveles es: 50% INFO, 25% WARN, 25% ERROR.
# El intervalo entre entradas es 0.5-2 s, lo que genera datos visibles
# en CloudWatch Metrics en menos de un minuto desde el arranque.

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.app.name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    log_group_name = aws_cloudwatch_log_group.app.name
  })

  tags = {
    Name      = "${var.project}-app"
    Project   = var.project
    ManagedBy = "terraform"
  }
}
