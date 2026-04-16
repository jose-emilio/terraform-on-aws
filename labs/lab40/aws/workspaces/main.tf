# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ══════════════════════════════════════════════════════════════════════════════
# BUCKETS DE WORKSPACE POR ENTORNO — version inicial con count
#
# ATENCION — LABORATORIO: este bloque usa count intencionalmente como
# punto de partida. En el Paso 2 lo migraras a for_each usando bloques
# moved. En el Paso 3 lo extraeras al modulo ./modules/s3_workspace.
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "workspace" {
  count  = length(var.environments)
  bucket = "${var.project}-ws-${var.environments[count.index]}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project}-ws-${var.environments[count.index]}"
    Environment = var.environments[count.index]
    Project     = var.project
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "workspace" {
  count  = length(var.environments)
  bucket = aws_s3_bucket.workspace[count.index].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "workspace" {
  count  = length(var.environments)
  bucket = aws_s3_bucket.workspace[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── SSM: nombre del bucket de cada entorno ────────────────────────────────────
resource "aws_ssm_parameter" "workspace_bucket" {
  count = length(var.environments)
  name  = "/${var.project}/${var.environments[count.index]}/bucket-name"
  type  = "String"
  value = aws_s3_bucket.workspace[count.index].bucket

  tags = {
    Project     = var.project
    Environment = var.environments[count.index]
    ManagedBy   = "terraform"
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# PARAMETROS DE CONFIGURACION DE LA APLICACION — for_each desde el inicio
#
# Estos 20 parametros no tienen dependencias entre si ni con los buckets,
# lo que los convierte en candidatos ideales para medir el impacto del
# flag -parallelism en el Paso 4 (10 workers vs 30 workers).
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_ssm_parameter" "config" {
  for_each = var.config_params

  name  = "/${var.project}/app/config/${each.key}"
  type  = "String"
  value = each.value

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
