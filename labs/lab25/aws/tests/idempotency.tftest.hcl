# ===========================================================================
# Test de idempotencia — Verificar estabilidad tras apply
# ===========================================================================
# Ejecuta apply y luego plan para confirmar que no hay cambios pendientes.
# Un módulo idempotente no debe generar diffs en el segundo plan.
#
# AVISO: Requiere credenciales de AWS (crea recursos reales temporalmente).

variables {
  project_name  = "lab25-idemp"
  bucket_suffix = "stable"
  environment   = "lab"
}

# --- Paso 1: Despliegue inicial ---

run "initial_deploy" {
  command = apply

  assert {
    condition     = output.bucket_id != ""
    error_message = "El bucket debe crearse en el primer apply"
  }
}

# --- Paso 2: Verificar que no hay cambios pendientes ---

run "no_changes_on_replan" {
  command = plan

  assert {
    condition     = output.bucket_id == run.initial_deploy.bucket_id
    error_message = "El bucket_id no debe cambiar entre apply y plan: '${output.bucket_id}' vs '${run.initial_deploy.bucket_id}'"
  }

  assert {
    condition     = output.bucket_arn == run.initial_deploy.bucket_arn
    error_message = "El bucket_arn no debe cambiar entre apply y plan"
  }
}
