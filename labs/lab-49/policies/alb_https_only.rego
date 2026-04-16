# Paquete: terraform.aws.alb
# Propósito: garantizar que ningún listener de Application Load Balancer (ALB) use el protocolo HTTP inseguro.
#
# Uso desde CLI:
#   terraform plan -out=plan.tfplan
#   terraform show -json plan.tfplan > plan.json
#   conftest test plan.json --policy policies/

package terraform.aws.alb

import rego.v1

deny contains msg if {
  resource := input.resource_changes[_]
  resource.type == "aws_lb_listener"

  # "some action in" es el patrón v1 para iterar y verificar membresía
  some action in resource.change.actions
  action in {"create", "update"}

  resource.change.after.protocol == "HTTP"

  msg := sprintf(
    "VIOLACIÓN [ALB-001] — '%s': uso de HTTP prohibido. Migra a HTTPS (puerto 443) con un certificado ACM.",
    [resource.address]
  )
}
