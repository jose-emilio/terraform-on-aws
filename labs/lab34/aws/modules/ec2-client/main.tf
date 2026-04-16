# ── AMI Amazon Linux 2023 ────────────────────────────────────────────────────

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ── Security Group de EC2 ─────────────────────────────────────────────────────

resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2"
  description = "SG para la instancia EC2 cliente del laboratorio"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project}-ec2" })
}

# ── IAM Role (SSM) ────────────────────────────────────────────────────────────
#
# AmazonSSMManagedInstanceCore habilita el acceso mediante Session Manager
# sin puerto SSH ni bastion host — el modelo recomendado para subnets privadas.

resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── Instancia EC2 ─────────────────────────────────────────────────────────────
#
# La etiqueta Backup=true es la que usa la politica DLM para seleccionar
# tanto la instancia como el volumen EBS de datos.

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = merge(var.tags, {
    Name   = "${var.project}-app"
    Backup = "true"
  })
}

# ── Volumen EBS gp3 de alto rendimiento ───────────────────────────────────────
#
# gp3 desacopla IOPS y throughput del tamanyo del volumen. Los 6 000 IOPS y
# 400 MB/s configurados aqui exceden lo que ofreceria gp2 para 100 GB
# (300 IOPS), al mismo coste base de almacenamiento.

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = var.ebs_size_gb
  type              = "gp3"
  iops              = var.ebs_iops
  throughput        = var.ebs_throughput
  encrypted         = true

  tags = merge(var.tags, {
    Name   = "${var.project}-data"
    Backup = "true"
  })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}
