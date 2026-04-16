# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  public_subnets = {
    "${var.region}a" = "10.30.0.0/24"
    "${var.region}b" = "10.30.10.0/24"
  }
  private_subnets = {
    "${var.region}a" = "10.30.1.0/24"
    "${var.region}b" = "10.30.2.0/24"
  }
}

# ── Modulo: VPC ───────────────────────────────────────────────────────────────
#
# El modulo vpc encapsula la VPC y las subnets privadas en dos AZs.
# Dos subnets son necesarias para desplegar un mount target de EFS en cada AZ;
# EFS replica los datos entre AZs de forma transparente.

module "vpc" {
  source = "./modules/vpc"

  project         = var.project
  tags            = local.tags
  cidr_block      = "10.30.0.0/16"
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}

# ── Modulo: EC2 cliente + EBS gp3 ─────────────────────────────────────────────
#
# El modulo ec2-client encapsula la instancia EC2, su Security Group, el rol
# IAM con SSM, el volumen EBS gp3 de alto rendimiento y su adjunto.
# La instancia se despliega en la primera AZ para minimizar la latencia al
# mount target de EFS de esa misma AZ.

module "ec2" {
  source = "./modules/ec2-client"

  project        = var.project
  tags           = local.tags
  vpc_id         = module.vpc.vpc_id
  subnet_id      = module.vpc.private_subnets["${var.region}a"]
  instance_type  = var.instance_type
  ebs_iops       = 6000
  ebs_throughput = 400
  ebs_size_gb    = 100
}

# ── Data Lifecycle Manager (DLM) ──────────────────────────────────────────────
#
# DLM automatiza la creacion y eliminacion de snapshots EBS basandose en
# etiquetas. La politica selecciona todos los volumenes con Backup=true,
# crea un snapshot diario a las 03:00 UTC y conserva los 14 mas recientes.
# El rol IAM predefinido AWSDataLifecycleManagerServiceRole ya incluye los
# permisos necesarios para crear snapshots y etiquetarlos.

resource "aws_iam_role" "dlm" {
  name = "${var.project}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ebs_backup" {
  description        = "Snapshots diarios EBS - etiqueta Backup true - retencion 14 dias"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "daily-14d"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 14
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Project         = var.project
      }

      copy_tags = true
    }
  }

  tags = local.tags
}

# ── Modulo: EFS compartido ────────────────────────────────────────────────────
#
# El modulo efs-share encapsula el Security Group NFS, el file system EFS,
# los mount targets en cada subnet y el Access Point de la aplicacion.
# Pasar el Security Group de EC2 permite al modulo restringir NFS (TCP 2049)
# exclusivamente a las instancias de este laboratorio, sin hardcodear CIDRs.

module "efs_share" {
  source = "./modules/efs-share"

  project    = var.project
  tags       = local.tags
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  ec2_sg_id  = module.ec2.security_group_id
  app_uid    = var.app_uid
  app_gid    = var.app_gid
}
