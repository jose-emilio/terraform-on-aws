# Modulo efs-share — version LocalStack.
#
# Limitaciones conocidas en Community:
#   aws_efs_file_system  — cifrado aceptado; no se aplica cifrado real.
#                          throughput_mode = "elastic" aceptado sin efecto real.
#   aws_efs_mount_target — recurso creado; no monta realmente trafico NFS.
#   aws_efs_access_point — recurso creado; posix_user y root_directory aceptados.
#
# Todos los recursos se crean sin error y permiten verificar la configuracion
# mediante awslocal efs describe-*.

resource "aws_security_group" "efs" {
  name        = "${var.project}-efs"
  description = "Permite NFS TCP 2049 desde instancias EC2 del laboratorio"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS desde EC2"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.ec2_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project}-efs" })
}

resource "aws_efs_file_system" "main" {
  encrypted        = true
  throughput_mode  = "elastic"
  performance_mode = "generalPurpose"

  tags = merge(var.tags, { Name = "${var.project}-efs" })
}

resource "aws_efs_mount_target" "main" {
  for_each = var.subnet_ids

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "app" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = var.app_uid
    gid = var.app_gid
  }

  root_directory {
    path = "/app/data"
    creation_info {
      owner_uid   = var.app_uid
      owner_gid   = var.app_gid
      permissions = "750"
    }
  }

  tags = merge(var.tags, { Name = "${var.project}-app-ap" })
}
