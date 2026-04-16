# Version LocalStack de Lab34.
#
# Limitaciones conocidas en Community:
#   aws_dlm_lifecycle_policy — NO disponible; recurso omitido.
#   aws_instance             — estado "running" simulado.
#   aws_ebs_volume           — iops/throughput aceptados sin efecto real.
#   aws_efs_file_system      — cifrado y throughput_mode aceptados sin efecto real.
#   aws_efs_mount_target     — recurso creado; sin montaje NFS real.
#   aws_efs_access_point     — posix_user y root_directory verificables.

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  private_subnets = {
    "us-east-1a" = "10.30.1.0/24"
    "us-east-1b" = "10.30.2.0/24"
  }
}

# ── Modulo: VPC ───────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  project         = var.project
  tags            = local.tags
  cidr_block      = "10.30.0.0/16"
  private_subnets = local.private_subnets
}

# ── Modulo: EC2 cliente + EBS gp3 ─────────────────────────────────────────────

module "ec2" {
  source = "./modules/ec2-client"

  project        = var.project
  tags           = local.tags
  vpc_id         = module.vpc.vpc_id
  subnet_id      = module.vpc.private_subnets["us-east-1a"]
  ebs_iops       = 6000
  ebs_throughput = 400
  ebs_size_gb    = 100
}

# ── DLM omitido ───────────────────────────────────────────────────────────────
# aws_dlm_lifecycle_policy no esta disponible en LocalStack Community.

# ── EFS omitido ───────────────────────────────────────────────────────────────
# aws_efs_file_system (y sus recursos asociados) requiere licencia de pago en
# LocalStack. El modulo efs-share queda excluido de esta version.
