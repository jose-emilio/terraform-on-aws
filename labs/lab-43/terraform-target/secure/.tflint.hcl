# ── Configuracion de TFLint para el Runner de IaC ─────────────────────────────
#
# Identica a la configuracion del directorio insecure/.
# Se incluye en ambos directorios para que el runner encuentre la configuracion
# de TFLint independientemente del directorio que se suba al bucket S3.

plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
}
