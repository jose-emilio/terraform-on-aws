# ─── Data Source: AMI dinámica ────────────────────────────────────────────────
# En LocalStack el data source aws_ami devuelve AMIs simuladas.
# Se mantiene el mismo filtro que en AWS real para coherencia.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── IAM Instance Profile ────────────────────────────────────────────────────
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

  # IMDSv2 obligatorio — mismo comportamiento que en AWS real
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.app_name}-web"
    Env  = var.env
  }
}
