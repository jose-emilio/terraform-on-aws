# ===========================================================================
# Test de integración — Despliegue real en AWS
# ===========================================================================
# Crea recursos reales en la cuenta de AWS para verificar que el módulo
# funciona de extremo a extremo. terraform test destruye los recursos
# automáticamente al finalizar.
#
# AVISO: Este test genera costes mínimos (S3 es prácticamente gratuito)
#        y requiere credenciales de AWS configuradas.

variables {
  project_name  = "lab25-inttest"
  bucket_suffix = "integration"
  environment   = "lab"
}

# --- Test 1: El bucket se crea correctamente ---

run "bucket_is_created" {
  command = apply

  assert {
    condition     = output.bucket_arn != ""
    error_message = "El bucket debe tener un ARN tras el apply"
  }

  assert {
    condition     = startswith(output.bucket_arn, "arn:aws:s3:::")
    error_message = "El ARN debe ser un ARN de S3 válido, got: ${output.bucket_arn}"
  }
}

# --- Test 2: Los tags se aplicaron correctamente ---

run "tags_are_applied" {
  command = plan

  assert {
    condition     = output.effective_tags["Project"] == "lab25-inttest"
    error_message = "El tag Project no coincide tras el apply"
  }

  assert {
    condition     = output.effective_tags["Environment"] == "lab"
    error_message = "El tag Environment no coincide tras el apply"
  }
}
