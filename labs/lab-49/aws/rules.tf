# =============================================================================
# Config Rule 1: Volúmenes EBS sin cifrar (control detectivo)
# =============================================================================
# Regla gestionada: ENCRYPTED_VOLUMES
# Tipo de evaluación: CONFIGURATION_CHANGE
# Recursos evaluados: AWS::EC2::Volume
#
# Esta regla evalúa automáticamente todos los volúmenes EBS cuando su estado
# cambia (creación, modificación). Un volumen es COMPLIANT si:
#   - Tiene cifrado habilitado (encrypted = true)
#
# Un volumen es NON_COMPLIANT si:
#   - No tiene cifrado habilitado
#
# Nota: la regla NO tiene remediación automática en este laboratorio.
# La corrección de un volumen sin cifrar requiere:
#   1. Crear snapshot del volumen existente
#   2. Copiar el snapshot con cifrado habilitado
#   3. Crear nuevo volumen desde el snapshot cifrado
#   4. Reemplazar el volumen en la instancia (requiere parada de la instancia)
# Este proceso es invasivo y no se puede automatizar sin ventana de mantenimiento.
# El Reto 1 del laboratorio propone automatizar el paso 1 (snapshot).

resource "aws_config_config_rule" "ebs_encrypted" {
  name        = "lab49-ebs-encrypted-volumes"
  description = "Detecta volúmenes EBS no cifrados. Los volúmenes no cifrados exponen datos en reposo sin protección criptográfica."

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  # La regla solo puede evaluarse si el recorder está activo y entregando.
  # Sin este depends_on, Terraform intentaría crear la regla antes de que
  # Config esté listo para evaluarla y el apply fallaría.
  depends_on = [aws_config_configuration_recorder_status.main]
}

# =============================================================================
# Config Rule 2: Buckets S3 con acceso público (control detectivo + correctivo)
# =============================================================================
# Regla gestionada: S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED
# Tipo de evaluación: CONFIGURATION_CHANGE
# Recursos evaluados: AWS::S3::Bucket
#
# Esta regla comprueba que los cuatro ajustes de Block Public Access están
# habilitados a nivel de bucket:
#   - BlockPublicAcls       = true
#   - IgnorePublicAcls      = true
#   - BlockPublicPolicy     = true
#   - RestrictPublicBuckets = true
#
# Un bucket es NON_COMPLIANT si CUALQUIERA de los cuatro ajustes es false.
#
# A diferencia de la regla de EBS, esta SÍ tiene remediación automática
# configurada en remediation.tf: cuando se detecta NON_COMPLIANT, SSM
# Automation ejecuta AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock
# que restaura los cuatro ajustes a true automáticamente.

resource "aws_config_config_rule" "s3_public_access_prohibited" {
  name        = "lab49-s3-public-access-prohibited"
  description = "Detecta buckets S3 con Block Public Access deshabilitado. La remediación automática restaura los cuatro ajustes de bloqueo."

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
