# policies/ssm.rego
package terraform

deny contains msg if {
  some r in input.resource_changes
  r.type == "aws_ssm_parameter"
  r.change.after != null
  r.change.after.type != "SecureString"
  msg := sprintf("SSM: '%v' debe ser de tipo SecureString", [r.address])
}
