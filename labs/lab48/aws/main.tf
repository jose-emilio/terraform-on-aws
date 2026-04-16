# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── AMI: Amazon Linux 2023 x86_64 (la más reciente) ──────────────────────────
#
# Se usa un data source para no hardcodear el ID de AMI, que cambia con cada
# actualización. filter por name con comodín garantiza siempre la última versión
# publicada por AWS. owner "amazon" evita AMIs de terceros o maliciosas.
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

# ═══════════════════════════════════════════════════════════════════════════════
# Módulo de naming — instancias para cada componente del laboratorio
# ═══════════════════════════════════════════════════════════════════════════════
#
# El módulo de naming se instancia una vez por recurso que necesita un nombre.
# En un proyecto real lo invocarías desde el módulo que crea el recurso.
# Aquí lo centralizamos en main.tf para ilustrar el patrón completo.
#
# Patrón de invocación:
#   module.naming["<clave>"].name   → nombre completo del recurso
#   module.naming["<clave>"].prefix → prefijo sin tipo de recurso

module "naming" {
  source = "./modules/naming"

  for_each = {
    vpc        = { component = "network", resource = "vpc" }
    igw        = { component = "network", resource = "igw" }
    sn_pub_a   = { component = "network", resource = "snpuba" }
    sn_pub_b   = { component = "network", resource = "snpubb" }
    rt_pub     = { component = "network", resource = "rtpub" }
    sg_asg     = { component = "compute", resource = "sg" }
    lt         = { component = "compute", resource = "lt" }
    asg        = { component = "compute", resource = "asg" }
    iam_role   = { component = "compute", resource = "role" }
    sns_budget = { component = "finops", resource = "sns" }
    budget     = { component = "finops", resource = "budget" }
  }

  app       = var.app_name
  env       = var.environment
  component = each.value.component
  resource  = each.value.resource
}
