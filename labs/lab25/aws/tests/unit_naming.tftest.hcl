# ===========================================================================
# Test unitario — Lógica de nombrado y etiquetado (sin AWS)
# ===========================================================================
# Usa mock_provider para simular AWS. No se conecta a ninguna cuenta,
# no genera costes, y se ejecuta en segundos.
# Usa command = apply (no plan) porque con mock_provider los atributos
# computados (como bucket.id) solo están disponibles tras el apply simulado.
# Con mock_provider, apply es instantáneo — no crea recursos reales.
# Requiere: Terraform >= 1.7

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDACKCEVSQ6C2EXAMPLE"
    }
  }
}

# --- Test 1: Nombre del bucket sigue la convención ---

run "bucket_name_follows_convention" {
  command = apply

  variables {
    project_name  = "myapp"
    bucket_suffix = "logs"
    environment   = "production"
  }

  assert {
    condition     = output.bucket_id == "myapp-logs-123456789012"
    error_message = "El nombre del bucket debe ser '{project}-{suffix}-{account_id}', got: ${output.bucket_id}"
  }
}

# --- Test 2: Tags por defecto incluyen los campos obligatorios ---

run "default_tags_are_present" {
  command = apply

  variables {
    project_name  = "myapp"
    bucket_suffix = "data"
    environment   = "dev"
  }

  assert {
    condition     = output.effective_tags["Project"] == "myapp"
    error_message = "El tag Project debe coincidir con project_name"
  }

  assert {
    condition     = output.effective_tags["Environment"] == "dev"
    error_message = "El tag Environment debe coincidir con environment"
  }

  assert {
    condition     = output.effective_tags["ManagedBy"] == "terraform"
    error_message = "El tag ManagedBy debe ser 'terraform'"
  }
}

# --- Test 3: Cambiar proyecto cambia el nombre ---

run "different_project_changes_name" {
  command = apply

  variables {
    project_name  = "otherapp"
    bucket_suffix = "backups"
    environment   = "lab"
  }

  assert {
    condition     = output.bucket_id == "otherapp-backups-123456789012"
    error_message = "Cambiar project_name debe cambiar el nombre del bucket"
  }
}
