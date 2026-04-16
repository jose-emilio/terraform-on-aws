# ═══════════════════════════════════════════════════════════════════════════════
# Consumidor — módulo VPC desde el registro privado de CodeArtifact
# ═══════════════════════════════════════════════════════════════════════════════
#
# Este proyecto simula un equipo de plataforma que consume el modulo vpc-module
# descargado desde CodeArtifact y servido como ruta local a Terraform.
#
# ANTES de ejecutar terraform init:
#   1. Descarga el asset con get-package-version-asset (ver Paso 5a del lab).
#   2. Extrae el tar.gz en /tmp/vpc-module.
#   3. Sustituye CODEARTIFACT_MODULE_URL por /tmp/vpc-module (ver Paso 5b).
#
# Los generic packages de CodeArtifact no exponen endpoint HTTP con Basic auth;
# la descarga se hace via AWS CLI con las credenciales del consumidor.

module "vpc" {
  source = "CODEARTIFACT_MODULE_URL"

  name                 = "lab42-consumer"
  cidr_block           = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]

  tags = {
    ManagedBy = "terraform"
    Source    = "codeartifact"
    Module    = "vpc-module"
    Version   = "1.0.0"
  }
}

output "vpc_id" {
  description = "ID del VPC creado por el modulo descargado desde CodeArtifact."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs de las subredes publicas."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas."
  value       = module.vpc.private_subnet_ids
}
