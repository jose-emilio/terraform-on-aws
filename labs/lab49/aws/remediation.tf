# =============================================================================
# IAM Role para SSM Automation (remediación)
# =============================================================================
# Cuando Config detecta un recurso NON_COMPLIANT y la remediación automática
# está habilitada, SSM Automation necesita asumir un rol IAM para ejecutar las
# acciones de corrección. Este rol es el "executor" de la remediación.
#
# Dos requisitos críticos:
# 1. Trust policy: permite a ssm.amazonaws.com asumir el rol
# 2. Permisos: mínimos permisos necesarios para la acción de remediación concreta
#
# Si este rol falta o tiene permisos incorrectos, la ejecución de SSM Automation
# fallará con AccessDenied y la remediación no ocurrirá — sin ningún error visible
# en la consola de Config. El diagnóstico requiere revisar los logs de SSM Automation.

resource "aws_iam_role" "remediation" {
  name        = "lab49-remediation-role"
  description = "Rol que asume SSM Automation para ejecutar remediaciones de Config."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Política inline con permisos mínimos para bloquear el acceso público en S3.
# Se usa una política inline (en lugar de una gestionada) porque los permisos
# son muy específicos — evitamos otorgar más acceso del necesario (principio
# de mínimo privilegio).
resource "aws_iam_role_policy" "remediation_s3" {
  name = "lab49-remediation-s3-policy"
  role = aws_iam_role.remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permisos necesarios para el documento SSM
        # AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock:
        #   - PutBucketPublicAccessBlock: habilita los 4 ajustes de bloqueo
        #   - GetBucketPublicAccessBlock: lee el estado actual antes de modificar
        Sid      = "AllowS3PublicAccessBlockManagement"
        Effect   = "Allow"
        Action   = [
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketPublicAccessBlock"
        ]
        Resource = "*"
      },
      {
        # El documento SSM necesita describir el bucket para obtener su nombre
        # a partir del RESOURCE_ID proporcionado por Config.
        Sid      = "AllowS3BucketDescribe"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# Remediación automática para S3 con acceso público
# =============================================================================
# Este recurso conecta la regla Config (detectivo) con SSM Automation (correctivo).
#
# Flujo de ejecución:
#   1. Config detecta bucket S3 con Block Public Access deshabilitado → NON_COMPLIANT
#   2. aws_config_remediation_configuration dispara SSM Automation automáticamente
#   3. SSM Automation asume el rol "lab49-remediation-role"
#   4. El documento AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock ejecuta:
#      s3:PutBucketPublicAccessBlock con los 4 ajustes en true
#   5. Config re-evalúa el bucket → COMPLIANT
#
# Parámetros especiales:
#   - static_value: valor fijo igual para todos los recursos remediados
#   - resource_value = "RESOURCE_ID": Config sustituye esto por el ID del recurso
#     no-conforme en tiempo de ejecución. Para S3, el RESOURCE_ID es el nombre del bucket.

resource "aws_config_remediation_configuration" "s3_public_access" {
  config_rule_name = aws_config_config_rule.s3_public_access_prohibited.name

  resource_type = "AWS::S3::Bucket"
  target_type   = "SSM_DOCUMENT"
  target_id     = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }

  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }

  # automatic = true: la remediación se dispara sin intervención humana.
  # Con automatic = false, un operador debería disparar la remediación manualmente
  # desde la consola de Config o via API.
  automatic = true

  # Número máximo de intentos antes de marcar la remediación como fallida.
  # Después de agotar los intentos, Config no reintentará hasta que el recurso
  # sea re-evaluado (por un cambio de configuración o una evaluación manual).
  maximum_automatic_attempts = 3

  # Segundos de espera entre reintentos fallidos.
  retry_attempt_seconds = 60

  # Controles de ejecución: evitan saturar las cuotas de la API en cuentas
  # con muchos recursos no-conformes remediándose simultáneamente.
  execution_controls {
    ssm_controls {
      # Máximo porcentaje de recursos remediándose en paralelo.
      # Con 100 buckets no-conformes, máximo 25 se remedian simultáneamente.
      concurrent_execution_rate_percentage = 25

      # Si más del 20% de las ejecuciones fallan, detener la remediación masiva
      # para evitar un "efecto dominó" de cambios fallidos.
      error_percentage = 20
    }
  }
}
