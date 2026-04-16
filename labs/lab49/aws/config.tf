# =============================================================================
# IAM Role para AWS Config
# =============================================================================
# AWS Config necesita un rol para poder describir recursos de la cuenta
# (permisos de lectura) y escribir en el bucket S3 de entrega.
# La política gestionada AWS_ConfigRole otorga exactamente esos permisos.

resource "aws_iam_role" "config" {
  name        = "lab49-config-role"
  description = "Rol que asume el servicio AWS Config para grabar y entregar configuraciones."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# =============================================================================
# Bucket S3 para la entrega de Config
# =============================================================================
# Config almacena en este bucket:
# - Snapshots periódicos de la configuración de todos los recursos (JSON)
# - Historial de cambios de configuración por recurso
# - Archivo de verificación de escritura (ConfigWritabilityCheckFile)
#
# force_destroy = true permite eliminarlo con "terraform destroy" incluso
# si contiene objetos. En producción esto debería ser false.

resource "aws_s3_bucket" "config_delivery" {
  bucket        = "lab49-config-delivery-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bloquea el acceso público al bucket — los snapshots de Config pueden contener
# información sensible sobre la configuración de tu cuenta.
resource "aws_s3_bucket_public_access_block" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Política del bucket que permite a Config verificar el ACL y escribir objetos.
# Sin esta política, el recorder se activa pero la entrega de snapshots falla
# con InsufficientDeliveryPolicyException (silenciosamente, sin alarma visible).
resource "aws_s3_bucket_policy" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  # La política depende del bloqueo de acceso público para que no haya
  # conflicto entre políticas de bucket y Block Public Access.
  depends_on = [aws_s3_bucket_public_access_block.config_delivery]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Config verifica que tiene acceso al bucket antes de escribir.
        # Sin este statement, la entrega falla antes de intentar escribir.
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_delivery.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # Config escribe los snapshots bajo el prefijo AWSLogs/{account-id}/Config/
        # La condición bucket-owner-full-control garantiza que el propietario del
        # bucket (tu cuenta) conserva el control total sobre los objetos escritos
        # por Config (que actúa como un principal externo de servicio).
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_delivery.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"     = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# =============================================================================
# Configuration Recorder
# =============================================================================
# El recorder define QUÉ grabar (all_supported = todos los tipos de recurso
# soportados) y CON QUÉ rol (role_arn = el rol IAM creado arriba).
#
# include_global_resource_types = true: graba también recursos globales como
# usuarios y roles IAM. Sin esto, las reglas Config que evalúan IAM no tendrían
# datos de configuración que leer.

resource "aws_config_configuration_recorder" "main" {
  name     = "lab49-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# =============================================================================
# Delivery Channel
# =============================================================================
# El delivery channel define DÓNDE entrega Config los datos grabados.
# Debe crearse antes de activar el recorder (gestionado con depends_on).
#
# snapshot_delivery_properties.delivery_frequency: con qué frecuencia Config
# entrega un snapshot completo de todos los recursos (además de los cambios
# incrementales que se entregan en tiempo real).

resource "aws_config_delivery_channel" "main" {
  name           = "lab49-delivery"
  s3_bucket_name = aws_s3_bucket.config_delivery.bucket

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# =============================================================================
# Activar el Recorder
# =============================================================================
# El recorder se crea en estado "deshabilitado". Este recurso lo activa.
# Depende del delivery channel porque el recorder necesita un destino válido
# antes de poder empezar a grabar — si no hay canal, la activación falla.

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}
