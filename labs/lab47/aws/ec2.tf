# ═══════════════════════════════════════════════════════════════════════════════
# AMI — Amazon Linux 2023 (x86_64, más reciente)
# ═══════════════════════════════════════════════════════════════════════════════

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Security Group — Reglas de tráfico para la instancia generadora
# ═══════════════════════════════════════════════════════════════════════════════
#
# Inbound:
#   Puerto 22 (SSH): abierto a internet deliberadamente para atraer tráfico de
#   escáneres y bots. Todo intento de conexión a otros puertos generará un
#   registro REJECT en el VPC Flow Log — materia prima del laboratorio.
#
# Outbound:
#   Todo el tráfico saliente está permitido. Esto genera registros ACCEPT en el
#   Flow Log cuando la instancia hace peticiones HTTP/HTTPS a internet.
#
# La combinación de tráfico entrante rechazado + saliente aceptado da lugar a
# un flujo de logs variado y realista para analizar con Log Insights.

resource "aws_security_group" "traffic_gen" {
  name        = "${var.project}-traffic-gen-sg"
  description = "SG de la instancia generadora de trafico del Lab47."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH - genera trafico REJECT en otros puertos"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Todo el trafico saliente - genera registros ACCEPT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-traffic-gen-sg", Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol de instancia para acceso vía SSM Session Manager
# ═══════════════════════════════════════════════════════════════════════════════
#
# SSM Session Manager permite abrir una terminal en la instancia sin necesidad
# de abrir el puerto 22 (aunque aquí está abierto deliberadamente para generar
# tráfico REJECT). La política AmazonSSMManagedInstanceCore es la mínima
# necesaria para que el agente SSM pre-instalado en Amazon Linux 2023 funcione.

resource "aws_iam_role" "traffic_gen" {
  name = "${var.project}-traffic-gen-role"

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
  role       = aws_iam_role.traffic_gen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "traffic_gen" {
  name = "${var.project}-traffic-gen-profile"
  role = aws_iam_role.traffic_gen.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# EC2 — Instancia generadora de tráfico en subred pública (AZ-a)
# ═══════════════════════════════════════════════════════════════════════════════
#
# La instancia tiene dos funciones en el laboratorio:
#
#   1. Generadora de tráfico saliente (ACCEPT):
#      El script en user_data lanza un bucle infinito que hace peticiones HTTP
#      periódicas a endpoints públicos. Cada petición genera un par de registros
#      en el Flow Log: uno de salida y uno de entrada (la respuesta).
#
#   2. Objetivo de tráfico entrante (REJECT):
#      Al tener IP pública, recibirá continuamente intentos de conexión de
#      escáneres automáticos de internet. El SG acepta solo el puerto 22; todos
#      los demás intentos generan registros REJECT, visibles en Log Insights.
#
# http_tokens = "required" activa IMDSv2 (Instance Metadata Service v2), que
# requiere un token de sesión antes de acceder a los metadatos. Evita ataques
# SSRF que intentan robar credenciales a través del endpoint 169.254.169.254.
#
# El VPC Flow Log monitoriza la ENI primaria de esta instancia específicamente
# (no toda la VPC), lo que permite ver exactamente el tráfico que genera.

resource "aws_instance" "traffic_gen" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.traffic_gen.id]
  iam_instance_profile   = aws_iam_instance_profile.traffic_gen.name

  metadata_options {
    http_tokens = "required"
  }

  user_data_base64 = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {}))

  tags = { Name = "${var.project}-traffic-gen", Project = var.project, ManagedBy = "terraform" }
}
