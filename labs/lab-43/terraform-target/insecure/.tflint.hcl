# ── Configuracion de TFLint para el Runner de IaC ─────────────────────────────
#
# Este fichero configura TFLint con el plugin de AWS y un conjunto de reglas
# que detectan errores logicos comunes en codigo Terraform orientado a AWS.
#
# El plugin 'aws' descarga reglas especificas del proveedor AWS que terraform
# validate no puede verificar porque no conoce las APIs de AWS:
#   - Tipos de instancia EC2 invalidos
#   - Familias de instancia RDS no existentes
#   - AMIs referenciadas con propiedades incorrectas
#   - Argumentos deprecados del proveedor AWS
#   - Valores invalidos en enumeraciones del proveedor (regiones, AZs...)

plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# ── Reglas de buenas practicas de Terraform ───────────────────────────────────

# Exige la declaracion explicita de required_version en el bloque terraform {}.
# Sin esta restriccion, el codigo puede ejecutarse con versiones incompatibles
# de Terraform y producir resultados diferentes o errores crypticos.
rule "terraform_required_version" {
  enabled = true
}

# Exige la declaracion de required_providers con source y version constraint.
# Sin version constraint, terraform init puede descargar una version del
# proveedor con breaking changes entre dos runs distintos.
rule "terraform_required_providers" {
  enabled = true
}

# Detecta el uso de variables no declaradas en el modulo.
rule "terraform_typed_variables" {
  enabled = true
}

# Advierte sobre nombres de recursos que no siguen las convenciones de
# nomenclatura de Terraform (snake_case, sin prefijo del proveedor).
rule "terraform_naming_convention" {
  enabled = true
}
