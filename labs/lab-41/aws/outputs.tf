# ── Repositorio ───────────────────────────────────────────────────────────────
output "repository_name" {
  description = "Nombre del repositorio CodeCommit (Fuente de la Verdad)."
  value       = aws_codecommit_repository.this.repository_name
}

output "repository_arn" {
  description = "ARN del repositorio CodeCommit."
  value       = aws_codecommit_repository.this.arn
}

output "repository_clone_url_http" {
  description = "URL de clonacion HTTPS. Requiere credenciales HTTPS de CodeCommit (generadas en IAM > Security credentials)."
  value       = aws_codecommit_repository.this.clone_url_http
}

output "repository_clone_url_ssh" {
  description = "URL de clonacion SSH. Requiere clave SSH subida al perfil IAM del usuario."
  value       = aws_codecommit_repository.this.clone_url_ssh
}

# ── Grupos IAM ────────────────────────────────────────────────────────────────
output "developer_group_name" {
  description = "Nombre del grupo IAM de desarrolladores."
  value       = aws_iam_group.developers.name
}

output "developer_group_arn" {
  description = "ARN del grupo IAM de desarrolladores."
  value       = aws_iam_group.developers.arn
}

output "tech_lead_group_name" {
  description = "Nombre del grupo IAM de lideres tecnicos."
  value       = aws_iam_group.tech_leads.name
}

output "tech_lead_group_arn" {
  description = "ARN del grupo IAM de lideres tecnicos."
  value       = aws_iam_group.tech_leads.arn
}

# ── Usuarios IAM ──────────────────────────────────────────────────────────────
output "developer_user_arns" {
  description = "ARNs de los usuarios IAM del equipo de desarrollo."
  value       = { for name, user in aws_iam_user.developer : name => user.arn }
}

output "tech_lead_user_arns" {
  description = "ARNs de los usuarios IAM de lideres tecnicos."
  value       = { for name, user in aws_iam_user.tech_lead : name => user.arn }
}

# ── Rol de aprobador ──────────────────────────────────────────────────────────
output "tech_lead_approver_role_arn" {
  description = "ARN del rol que los tech leads asumen para aprobar Pull Requests. Usado en el Approval Rule Template."
  value       = aws_iam_role.tech_lead.arn
}

output "tech_lead_approver_role_name" {
  description = "Nombre del rol de aprobador (para referencia en comandos aws sts assume-role)."
  value       = aws_iam_role.tech_lead.name
}

# ── Approval Rule Template ────────────────────────────────────────────────────
output "approval_rule_template_name" {
  description = "Nombre del Approval Rule Template asociado al repositorio."
  value       = aws_codecommit_approval_rule_template.tech_lead_required.name
}

output "approval_rule_template_id" {
  description = "ID unico del Approval Rule Template."
  value       = aws_codecommit_approval_rule_template.tech_lead_required.approval_rule_template_id
}

# ── KMS ───────────────────────────────────────────────────────────────────────
output "sns_kms_key_arn" {
  description = "ARN de la clave KMS que cifra el SNS Topic."
  value       = aws_kms_key.sns.arn
}

# ── SNS y notificaciones ──────────────────────────────────────────────────────
output "sns_topic_arn" {
  description = "ARN del SNS Topic de notificaciones de Pull Requests y auditoria."
  value       = aws_sns_topic.pr_notifications.arn
}

output "notification_rule_arn" {
  description = "ARN de la CodeStar Notification Rule (eventos de Pull Request)."
  value       = aws_codestarnotifications_notification_rule.pull_requests.arn
}

output "eventbridge_audit_rule_arn" {
  description = "ARN de la regla de EventBridge para auditoria de escrituras en main."
  value       = aws_cloudwatch_event_rule.main_branch_write_audit.arn
}

# ── Comandos de verificacion rapida ──────────────────────────────────────────
#
# Estos outputs consolidan los comandos de verificacion mas utiles para
# copiar y pegar directamente en la terminal tras el apply.
output "verify_commands" {
  description = "Comandos de verificacion rapida para ejecutar tras el apply."
  value       = <<-EOT

    # ── Verificar Approval Rule Template ──────────────────────────────────
    aws codecommit list-associated-approval-rule-templates-for-repository \
      --repository-name ${aws_codecommit_repository.this.repository_name} \
      --region ${var.region}

    # ── Asumir rol de tech lead para aprobar un PR ─────────────────────────
    aws sts assume-role \
      --role-arn ${aws_iam_role.tech_lead.arn} \
      --role-session-name "approve-pr-$(date +%s)"

    # ── Ver suscriptores del SNS Topic ────────────────────────────────────
    aws sns list-subscriptions-by-topic \
      --topic-arn ${aws_sns_topic.pr_notifications.arn} \
      --region ${var.region}

    # ── Ver ramas del repositorio ─────────────────────────────────────────
    aws codecommit list-branches \
      --repository-name ${aws_codecommit_repository.this.repository_name} \
      --region ${var.region}
  EOT
}
