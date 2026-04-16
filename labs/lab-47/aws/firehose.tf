# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Log Group — Log interno de errores de Kinesis Firehose
# ═══════════════════════════════════════════════════════════════════════════════
#
# Firehose puede registrar en CloudWatch los registros que no pudo entregar
# a S3 (errores de acceso, KMS, formato, etc.). Este log group actúa como
# canal de diagnóstico del propio pipeline de datos.
#
# IMPORTANTE: crear este log group explícitamente en Terraform garantiza que
# existe antes de que Firehose intente escribir en él y que hereda el cifrado
# KMS y la retención del resto del laboratorio. Si no se crea aquí, Firehose
# lo crearía sin cifrado ni retención definida.

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/${var.project}/firehose"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_stream" "firehose_delivery" {
  name           = "delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para que Kinesis Firehose entregue datos a S3
# ═══════════════════════════════════════════════════════════════════════════════
#
# Firehose asume este rol para acceder a S3 y KMS. Los permisos S3 siguen el
# principio de mínimo privilegio: solo puede escribir (PutObject) y listar el
# bucket necesario para gestionar las cargas multiparte.
#
# AbortMultipartUpload es crítico: sin él, si una carga multiparte falla a
# medias, las partes parciales quedan en S3 cobrándose indefinidamente. Es
# la contraparte del lifecycle abort_incomplete_multipart_upload.

resource "aws_iam_role" "firehose" {
  name = "${var.project}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "firehose" {
  name = "${var.project}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.archive.arn,
          "${aws_s3_bucket.archive.arn}/*"
        ]
      },
      {
        # Con bucket_key_enabled = true en el bucket, S3 gestiona internamente
        # la mayoría de las llamadas KMS con una clave de bucket. Firehose aún
        # necesita GenerateDataKey para el cifrado inicial antes de subir a S3.
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.main.arn
      },
      {
        # Permite a Firehose escribir sus propios errores de entrega en el
        # log group de diagnóstico. Solo se otorga acceso al stream "delivery".
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = ["logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:log-stream:${aws_cloudwatch_log_stream.firehose_delivery.name}"
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# Kinesis Firehose — Delivery stream: CloudWatch Logs → S3
# ═══════════════════════════════════════════════════════════════════════════════
#
# Firehose actúa como buffer inteligente entre CloudWatch Logs y S3. Los logs
# llegan en tiempo real desde la subscription filter, Firehose los acumula en
# memoria y los entrega a S3 cuando se cumple UNO de los dos umbrales:
#   - buffering_size: 5 MB acumulados (se alcanza antes en periodos de alto tráfico)
#   - buffering_interval: 300 segundos (garantiza entrega aunque no haya tráfico)
#
# prefix con expresiones temporales de Firehose:
#   !{timestamp:yyyy}  → año actual (ej: 2026)
#   !{timestamp:MM}    → mes con cero inicial (ej: 04)
#   !{timestamp:dd}    → día con cero inicial (ej: 13)
# Esto crea una estructura de particiones tipo Hive compatible con Athena y Glue,
# permitiendo queries eficientes por fecha sin escanear todo el bucket.
#
# compression_format = "GZIP": los archivos se comprimen antes de subir a S3.
# Los logs de texto plano de Flow Logs se comprimen típicamente en un 70-80%.
# Esto reduce tanto el coste de almacenamiento S3 como el de la transición
# a Glacier Deep Archive.
#
# error_output_prefix: los registros que Firehose no puede entregar (por errores
# de S3, KMS, formato, etc.) se redirigen a este prefijo con el tipo de error
# como subcarpeta, facilitando el diagnóstico post-incidente.

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = "${var.project}-logs-to-s3"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.archive.arn

    prefix              = "firehose/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "firehose-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/"

    buffering_size     = var.firehose_buffer_size_mb
    buffering_interval = var.firehose_buffer_interval_seconds

    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_delivery.name
    }
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para que CloudWatch Logs envíe registros a Firehose
# ═══════════════════════════════════════════════════════════════════════════════
#
# La subscription filter necesita que CloudWatch Logs pueda llamar a la API de
# Firehose (PutRecordBatch). Para ello, CloudWatch asume este rol IAM.
#
# La condición aws:SourceArn restringe qué log groups pueden usar este rol,
# evitando que otros log groups de la cuenta (que no sean el de flow logs)
# puedan usarlo para enviar datos a Firehose sin autorización.

resource "aws_iam_role" "cw_to_firehose" {
  name = "${var.project}-cw-to-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.${var.region}.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "cw_to_firehose" {
  name = "${var.project}-cw-to-firehose-policy"
  role = aws_iam_role.cw_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.logs.arn
    }]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Logs Subscription Filter — Reenvía Flow Logs a Firehose
# ═══════════════════════════════════════════════════════════════════════════════
#
# Una subscription filter conecta un log group de CloudWatch con un destino
# externo (Kinesis Data Streams, Kinesis Firehose o Lambda). Cuando llegan
# nuevas entradas al log group que coinciden con el filter_pattern, CloudWatch
# las reenvía al destino en tiempo casi real (latencia de segundos).
#
# filter_pattern = "" captura TODOS los registros del log group. Si se quisiera
# filtrar por IP origen específica o rango de puertos, se usaría la sintaxis
# de filter patterns de CloudWatch Logs:
#   "[v, account, eni, src, dst, srcport, dstport=22, ...]"
#
# Como el log group ya solo recibe tráfico REJECT (configurado en aws_flow_log),
# el filtro vacío es suficiente: todos los registros del grupo son REJECTs.
#
# distribution = "Random" distribuye los registros aleatoriamente entre los
# shards de Firehose cuando hay múltiples shards. Para un único shard (la
# configuración por defecto de este lab), no tiene efecto práctico.
#
# LÍMITE: CloudWatch Logs permite un máximo de 2 subscription filters por
# log group. Si se añade una segunda suscripción (ej: para Lambda en un reto),
# se llegará al límite.

resource "aws_cloudwatch_log_subscription_filter" "flow_logs_to_firehose" {
  name            = "${var.project}-flow-logs-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.flow_logs.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.logs.arn
  role_arn        = aws_iam_role.cw_to_firehose.arn
  distribution    = "Random"
}
