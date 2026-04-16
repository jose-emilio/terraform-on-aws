# ── Data Sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  account_id = data.aws_caller_identity.current.account_id
  caller_arn = data.aws_caller_identity.current.arn

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }

  # Si no se proporcionan administradores explícitos, se usa el caller actual.
  # Esto garantiza que siempre haya al menos un administrador y evita el error
  # "The new key policy will not allow you to update the key policy in the future"
  # que AWS lanza cuando ningún principal tiene kms:PutKeyPolicy.
  admin_arns = length(var.admin_principal_arns) > 0 ? var.admin_principal_arns : [local.caller_arn]
}

# ── Key Policy segregada ──────────────────────────────────────────────────────
#
# Una Key Policy en KMS tiene tres roles diferenciados:
#
#   1. Root account (Sid "EnableRootAccess"):
#      La cuenta raíz siempre debe tener acceso total para recuperar el control
#      ante cambios de policy incorrectos. Sin este statement, si se borran todos
#      los administradores, la llave queda irrecuperable.
#
#   2. Administradores (Sid "AllowKeyAdministration"):
#      Pueden gestionar el ciclo de vida de la llave (rotación, desactivación,
#      borrado programado, cambio de policy) pero NO pueden usarla para
#      cifrar/descifrar datos. La segregación impide que un administrador
#      de infraestructura pueda leer datos cifrados de producción.
#
#   3. Usuarios finales/aplicaciones (Sid "AllowKeyUsage"):
#      Pueden cifrar y descifrar datos pero NO pueden modificar la policy,
#      deshabilitar la llave ni programar su borrado. Es el único conjunto
#      de permisos que debe tener el rol de una aplicación.

data "aws_iam_policy_document" "cmk_policy" {
  # Statement 1 — Acceso total desde la cuenta raíz
  statement {
    sid    = "EnableRootAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Statement 2 — Administradores: gestión del ciclo de vida, sin uso de datos
  statement {
    sid    = "AllowKeyAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = local.admin_arns
    }

    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]

    resources = ["*"]
  }

  # Statement 3 — Usuarios finales: solo cifrado/descifrado
  # Se omite si app_principal_arns está vacío (condition evita policy inválida).
  dynamic "statement" {
    for_each = length(var.app_principal_arns) > 0 ? [1] : []
    content {
      sid    = "AllowKeyUsage"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.app_principal_arns
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]
    }
  }

  # Statement 4 — Permite que los servicios AWS (S3, EBS) usen la CMK
  # cuando el acceso viene de una solicitud de esos servicios en la misma cuenta.
  statement {
    sid    = "AllowAWSServicesViaGrants"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]

    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

# ── Customer Managed Key (CMK) ────────────────────────────────────────────────
#
# enable_key_rotation = true: KMS rota automáticamente el material criptográfico
# cada año. El alias y el Key ID permanecen igual — no hay cambios en el código.
# Los datos cifrados con material antiguo siguen siendo descifrables porque KMS
# mantiene todos los materiales históricos.
#
# deletion_window_in_days = 7: el mínimo que permite AWS (default = 30).
# Durante esta ventana la llave está deshabilitada pero no eliminada, lo que
# permite cancelar un borrado accidental con kms:CancelKeyDeletion.
#
# multi_region = false: llave regional. Para replicar datos cifrados entre
# regiones se necesitaría multi_region = true + aws_kms_replica_key.

resource "aws_kms_key" "main" {
  description             = "CMK del Lab13 — cifrado de EBS y S3"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  multi_region            = false
  policy                  = data.aws_iam_policy_document.cmk_policy.json

  tags = merge(local.tags, { Name = "${var.project}-cmk" })
}

# ── Alias ─────────────────────────────────────────────────────────────────────
#
# El alias es un nombre amigable que apunta al Key ID.
# Cuando se rota el material criptográfico o se sustituye la CMK por otra
# (por ejemplo tras un incidente), basta con apuntar el alias a la nueva llave.
# Todo el código que referencia "alias/lab13-main" sigue funcionando sin cambios.
#
# Convención de nombres: alias/<proyecto>-<propósito>
# Prefijo "alias/" es obligatorio y gestionado automáticamente por Terraform.

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-main"
  target_key_id = aws_kms_key.main.key_id
}

# ── Volumen EBS cifrado con la CMK ────────────────────────────────────────────
#
# encrypted = true + kms_key_id = alias ARN fuerzan el cifrado con la CMK.
# Si se omite kms_key_id pero se pone encrypted = true, AWS usa la llave
# gestionada por el servicio (aws/ebs) en lugar de la CMK personalizada.
#
# Diferencias CMK vs llave gestionada por servicio:
#   - CMK: control total de la policy, rotación configurable, auditable en CloudTrail.
#   - aws/ebs: sin control de policy, rotación automática por AWS, menor visibilidad.

resource "aws_ebs_volume" "main" {
  availability_zone = var.availability_zone
  size              = var.ebs_volume_size_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_alias.main.arn

  tags = merge(local.tags, { Name = "${var.project}-ebs" })
}

# ── Bucket S3 cifrado con la CMK ──────────────────────────────────────────────
#
# apply_server_side_encryption_by_default: cifra todos los objetos nuevos con
# la CMK especificada (SSE-KMS). Los objetos ya existentes no se re-cifran.
#
# bucket_key_enabled = true: activa S3 Bucket Key, que reduce las llamadas a
# la API de KMS generando una llave de datos temporal a nivel de bucket.
# Reduce el coste de KMS hasta un 99% en buckets con alta densidad de objetos.

resource "aws_s3_bucket" "main" {
  bucket        = "${var.project}-data-${local.account_id}"
  force_destroy = true

  tags = merge(local.tags, { Name = "${var.project}-data" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_alias.main.arn
    }
    bucket_key_enabled = true
  }
}

# Bloqueo de acceso público: el bucket es privado por defecto.
resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Política de bucket: deniega explícitamente cualquier carga de objeto que
# no use SSE-KMS. Esto impide que un cliente suba objetos sin cifrado o
# con una llave diferente, garantizando el cifrado forzoso.
resource "aws_s3_bucket_policy" "enforce_kms" {
  bucket = aws_s3_bucket.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonKMSUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringNotEqualsIfExists = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid       = "DenyWrongKMSKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringNotEqualsIfExists = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.main.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.main]
}
