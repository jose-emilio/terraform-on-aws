# policies/kms.rego
package terraform

deny contains msg if {
  some r in input.resource_changes
  r.type == "aws_kms_key"
  r.change.after != null
  not r.change.after.enable_key_rotation
  msg := sprintf("KMS: '%v' no tiene rotacion de clave habilitada", [r.address])
}
