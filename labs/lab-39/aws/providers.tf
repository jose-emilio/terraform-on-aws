terraform {
  required_version = ">= 1.5"  # bloque import + generate-config-out: 1.5
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuracion parcial del backend. Todos los parametros estan en
  # aws.s3.tfbackend. Usalo asi:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=terraform-state-labs-<ACCOUNT_ID>"
  backend "s3" {}
}

# ── Proveedor primario — us-east-1 ────────────────────────────────────────────
# El alias permite distinguir este proveedor del secundario cuando ambos
# usan el mismo provider "aws". Los recursos que no declaren 'provider'
# explicito usaran el proveedor sin alias (aqui no existe: TODOS deben
# declarar provider = aws.primary o provider = aws.secondary para evitar
# ambiguedades).
provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

# ── Proveedor secundario — eu-west-3 ─────────────────────────────────────────
# Mismo bloque provider "aws" con un alias diferente. Terraform distingue
# los dos bloques por el alias, no por el tipo. Los recursos que declaren
# provider = aws.secondary enviaran sus llamadas API a eu-west-3.
provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}
