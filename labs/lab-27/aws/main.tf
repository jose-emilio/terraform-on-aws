# ─── Data Source: AMI dinámica ────────────────────────────────────────────────
# Busca la AMI más reciente de Amazon Linux 2023 propiedad de Amazon.
# Al usar un data source en lugar de un ID fijo, la configuración es
# agnóstica a la región y siempre obtiene la última versión parcheada.
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

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── IAM Instance Profile ────────────────────────────────────────────────────
# Crea un rol IAM con la política AmazonSSMManagedInstanceCore para que la
# instancia pueda gestionarse mediante SSM Session Manager sin necesidad de
# abrir el puerto SSH ni usar Access Keys estáticas.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.app_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.app_name}-ec2-role"
    Env  = var.env
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${var.app_name}-ec2-profile"
    Env  = var.env
  }
}

# ─── Security Group ──────────────────────────────────────────────────────────
# Permite tráfico HTTP de entrada y todo el tráfico de salida.
# No se abre el puerto 22: el acceso se realiza mediante SSM Session Manager.

resource "aws_security_group" "web" {
  name        = "${var.app_name}-web-sg"
  description = "Permite HTTP entrante y todo el trafico saliente"

  tags = {
    Name = "${var.app_name}-web-sg"
    Env  = var.env
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP desde cualquier origen"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente"
}

# ─── User Data dinámico ──────────────────────────────────────────────────────
# templatefile() renderiza la plantilla .tftpl inyectando variables de
# Terraform (como db_endpoint) en el script de bootstrap antes del despliegue.
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    app_name    = var.app_name
    db_endpoint = var.db_endpoint
  })
}

# ─── Instancia EC2 ──────────────────────────────────────────────────────────
resource "aws_instance" "web" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data                   = local.user_data
  user_data_replace_on_change = true

  # Fuerza el uso de IMDSv2 (Instance Metadata Service v2).
  # Con http_tokens = "required" la instancia solo acepta peticiones al
  # metadata service que incluyan un token de sesión, bloqueando ataques
  # SSRF que intentan acceder a http://169.254.169.254 sin autenticación.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 obligatorio
  }

  tags = {
    Name = "${var.app_name}-web"
    Env  = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}
