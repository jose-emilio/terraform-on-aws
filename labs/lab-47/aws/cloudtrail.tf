# ═══════════════════════════════════════════════════════════════════════════════
# S3 Bucket Policy — Permite a CloudTrail escribir en el bucket de archivo
# ═══════════════════════════════════════════════════════════════════════════════
#
# CloudTrail no usa roles IAM para escribir en S3: usa una política de bucket.
# Esto significa que la autorización se resuelve en el lado del bucket, no en
# el lado del llamante. La política debe estar creada ANTES del trail
# (gestionado con depends_on en aws_cloudtrail).
#
# Statement 1 — GetBucketAcl: CloudTrail verifica los permisos del bucket antes
# de escribir. Sin este permiso, el trail falla silenciosamente al arrancar.
#
# Statement 2 — PutObject con condición s3:x-amz-acl = bucket-owner-full-control:
# Garantiza que los objetos escritos por CloudTrail pertenecen al propietario
# del bucket. Sin esta condición, los objetos podrían quedar "huérfanos" en
# buckets cross-account donde el propietario sería la cuenta de AWS que gestiona
# CloudTrail, no la cuenta propietaria del bucket.
#
# La condición aws:SourceArn en ambos statements es la defensa contra el
# "confused deputy attack": previene que un trail malicioso de otra cuenta
# use esta política para escribir en el bucket.

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.archive.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.project}-trail"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.archive.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.project}-trail"
          }
        }
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Log Group — Destino secundario de CloudTrail (tiempo real)
# ═══════════════════════════════════════════════════════════════════════════════
#
# CloudTrail tiene dos destinos de escritura:
#   1. S3 (primario): archivos JSON comprimidos, entregados cada ~5 minutos.
#      Útil para análisis histórico, Athena, exportaciones. Retención indefinida.
#   2. CloudWatch Logs (secundario): eventos en tiempo casi real, con latencia
#      de segundos. Útil para alarmas y Log Insights interactivo.
#
# Ambos pueden habilitarse simultáneamente. CloudWatch Logs es fundamental para
# detectar actividad sospechosa en tiempo real (acceso root, cambios de IAM).

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/${var.project}/cloudtrail"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para que CloudTrail escriba en CloudWatch Logs
# ═══════════════════════════════════════════════════════════════════════════════
#
# A diferencia de S3 (donde CloudTrail usa una bucket policy), para CloudWatch
# Logs CloudTrail necesita asumir un rol IAM. Este rol permite CreateLogStream
# (CloudTrail crea un stream por región) y PutLogEvents (escritura de eventos).
#
# Solo se otorgan los dos permisos mínimos necesarios. CloudTrail NO necesita
# CreateLogGroup porque el log group ya existe (creado por Terraform).

resource "aws_iam_role" "cloudtrail_cw" {
  name = "${var.project}-cloudtrail-cw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
        }
      }
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "cloudtrail_cw" {
  name = "${var.project}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_cw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudTrail — Trail multi-región con validación de integridad
# ═══════════════════════════════════════════════════════════════════════════════
#
# is_multi_region_trail = true: un único trail captura eventos de TODAS las
# regiones AWS. Sin esta opción, solo se registrarían los eventos de us-east-1.
# Servicios globales como IAM, STS y Route53 solo envían eventos a us-east-1,
# por lo que include_global_service_events = true es obligatorio en el trail
# de la región principal para no perder esos eventos.
#
# enable_log_file_validation = true: CloudTrail genera un archivo de resumen
# (digest) cada hora. Cada digest contiene el hash SHA-256 de cada archivo de
# log del periodo y está firmado digitalmente con RSA usando una clave privada
# de AWS. Esta cadena de hashes permite detectar si alguien:
#   - Modificó el contenido de un archivo de log
#   - Eliminó un archivo de log
#   - Insertó archivos de log falsos
# La validación se realiza con: aws cloudtrail validate-logs
#
# kms_key_id: cifra los archivos de log en S3 con la CMK del laboratorio.
# Sin cifrado, los archivos JSON son legibles por cualquier principal con
# acceso al bucket. Con KMS, se necesita acceso BOTH al bucket AND a la clave.
#
# cloud_watch_logs_group_arn: el ":*" al final es obligatorio; sin él,
# CloudTrail no puede escribir en los log streams del grupo.

resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.archive.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.main.arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cw.arn

  # Captura todos los eventos de gestión (creación/eliminación de recursos,
  # cambios de IAM, etc.) tanto de lectura como de escritura.
  # Los management events son gratuitos para el primer trail de cada región.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  # La política de bucket debe existir antes de que el trail intente escribir.
  depends_on = [aws_s3_bucket_policy.archive]

  tags = { Project = var.project, ManagedBy = "terraform" }
}
