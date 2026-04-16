# =============================================================================
# AWS Security Hub
# =============================================================================
# Security Hub actúa como el panel de mando unificado de seguridad.
# Agrega hallazgos de AWS Config, Inspector, GuardDuty, Macie y otros servicios
# normalizándolos en el formato ASFF (Amazon Security Finding Format).
#
# PREREQUISITO CRÍTICO: AWS Config debe estar habilitado y grabando antes de
# activar Security Hub. Sin el recorder activo, los controles de los estándares
# no pueden evaluar recursos y la puntuación de seguridad queda en 0%.
# El depends_on implícito a través de aws_securityhub_standards_subscription
# garantiza este orden cuando todo está en el mismo módulo raíz.

resource "aws_securityhub_account" "main" {
  # auto_enable_controls = true (default): Security Hub habilita automáticamente
  # todos los controles de los estándares a los que te suscribas. Con false,
  # los controles se crean en estado DISABLED y hay que habilitarlos manualmente.
  auto_enable_controls = true

  # enable_default_standards = false: no suscribir automáticamente al estándar
  # AWS Foundational Best Practices en el momento de habilitar el servicio.
  # Lo hacemos explícitamente con aws_securityhub_standards_subscription para
  # tener control declarativo del estado de las suscripciones.
  enable_default_standards = false
}

# =============================================================================
# Suscripción al estándar FSBP
# =============================================================================
# El estándar AWS Foundational Security Best Practices (FSBP) v1.0.0 es el
# conjunto de controles de seguridad fundamental definido por AWS.
# Cubre más de 300 controles distribuidos en:
#   EC2, S3, RDS, IAM, CloudTrail, Lambda, ECS, EKS, Redshift, etc.
#
# Al suscribirte, Security Hub crea automáticamente reglas de Config con el
# prefijo "securityhub-" para evaluar cada control. Por eso el recorder de
# Config debe estar activo — estas reglas necesitan configuración grabada.
#
# El ARN del estándar incluye la región porque los estándares de Security Hub
# son recursos regionales (aunque el estándar FSBP existe en todas las regiones).

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  # Security Hub debe estar habilitado antes de poder suscribirse a estándares.
  depends_on = [aws_securityhub_account.main]
}
