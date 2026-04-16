# ── Security Group: NFS (TCP 2049) ────────────────────────────────────────────
#
# Solo se permite trafico NFS desde el Security Group de las instancias EC2.
# Usar source_security_group_id en lugar de CIDR es mas seguro: el acceso se
# concede por identidad de SG, no por rango de IPs, y escala automaticamente
# cuando se lanzan nuevas instancias con ese SG.

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

# ── EFS File System ───────────────────────────────────────────────────────────
#
# encrypted = true usa la clave AWS gestionada para EFS (aws/elasticfilesystem).
# throughput_mode = "elastic" escala automaticamente el throughput en funcion
# de la actividad de lectura/escritura, sin necesidad de aprovisionar capacidad.
# Es mas economico que "provisioned" cuando el acceso es variable.

resource "aws_efs_file_system" "main" {
  encrypted        = true
  throughput_mode  = "elastic"
  performance_mode = "generalPurpose"

  tags = merge(var.tags, { Name = "${var.project}-efs" })
}

# ── Mount Targets ─────────────────────────────────────────────────────────────
#
# Un mount target por subnet (AZ). EFS replica los datos entre AZs de forma
# transparente; los mount targets son los puntos de entrada de red — cada
# instancia se conecta al mount target de su propia AZ para minimizar latencia
# y evitar cargos de transferencia de datos inter-AZ.

resource "aws_efs_mount_target" "main" {
  for_each = var.subnet_ids

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# ── Access Point ──────────────────────────────────────────────────────────────
#
# El Access Point virtualiza un directorio raiz (/app/data) dentro del EFS.
# Cuando una aplicacion monta el EFS a traves de este Access Point:
#   - El sistema operativo impone el UID/GID declarados en posix_user,
#     independientemente del usuario real con el que corra el proceso.
#   - El directorio root_directory.path actua como raiz del sistema de archivos:
#     la aplicacion solo ve /app/data y sus subdirectorios, no el resto del EFS.
# Esto permite aislar los datos de distintas aplicaciones en el mismo EFS.

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
