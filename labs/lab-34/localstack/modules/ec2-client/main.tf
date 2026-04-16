# Modulo ec2-client — version LocalStack.
#
# Limitaciones conocidas en Community:
#   aws_instance     — estado "running" simulado; sin EC2 real.
#   aws_ebs_volume   — volumen creado; iops/throughput aceptados sin efecto real.
#   aws_iam_role     — rol creado y verificable.

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

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "app" {
  ami                    = "ami-00000000"
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  depends_on             = [aws_iam_instance_profile.ec2]

  tags = merge(var.tags, {
    Name   = "${var.project}-app"
    Backup = "true"
  })
}

resource "aws_ebs_volume" "data" {
  availability_zone = "us-east-1a"
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
