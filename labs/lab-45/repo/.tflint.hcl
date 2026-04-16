plugin "aws" {
  enabled = true
  version = "0.37.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "local"
}

# Reglas de buenas practicas habilitadas explicitamente
rule "aws_resource_missing_tags" {
  enabled = false # Desactivado: las tags se aplican via default_tags en el provider
}

rule "aws_s3_bucket_name" {
  enabled = true
}
