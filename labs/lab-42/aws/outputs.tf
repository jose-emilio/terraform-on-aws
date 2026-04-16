# ── Dominio ───────────────────────────────────────────────────────────────────
output "domain_name" {
  description = "Nombre del dominio CodeArtifact."
  value       = aws_codeartifact_domain.this.domain
}

output "domain_arn" {
  description = "ARN del dominio CodeArtifact."
  value       = aws_codeartifact_domain.this.arn
}

output "domain_owner" {
  description = "ID de la cuenta propietaria del dominio."
  value       = aws_codeartifact_domain.this.owner
}

# El endpoint HTTPS del dominio se construye con el patron:
#   <domain>-<account>.d.codeartifact.<region>.amazonaws.com
# Este valor se usa en ~/.netrc y como base de las URLs de paquetes.
output "domain_endpoint" {
  description = "Hostname del endpoint HTTPS del dominio. Se usa como 'machine' en ~/.netrc."
  value       = "${aws_codeartifact_domain.this.domain}-${data.aws_caller_identity.current.account_id}.d.codeartifact.${var.region}.amazonaws.com"
}

# ── Repositorio ───────────────────────────────────────────────────────────────
output "repository_name" {
  description = "Nombre del repositorio CodeArtifact."
  value       = aws_codeartifact_repository.this.repository
}

output "repository_arn" {
  description = "ARN del repositorio CodeArtifact."
  value       = aws_codeartifact_repository.this.arn
}

# URL raiz del registro generic. Las URLs de paquetes individuales siguen el patron:
#   <generic_registry_url>/<namespace>/<package>/<version>/<asset>
output "generic_registry_url" {
  description = "URL raiz del registro generic. Apende /<namespace>/<paquete>/<version>/<asset> para obtener la URL de descarga."
  value       = "https://${aws_codeartifact_domain.this.domain}-${data.aws_caller_identity.current.account_id}.d.codeartifact.${var.region}.amazonaws.com/generic/${aws_codeartifact_repository.this.repository}"
}

# ── KMS ───────────────────────────────────────────────────────────────────────
output "kms_key_arn" {
  description = "ARN de la CMK que cifra el dominio CodeArtifact."
  value       = aws_kms_key.codeartifact.arn
}

output "kms_key_alias" {
  description = "Alias de la CMK."
  value       = aws_kms_alias.codeartifact.name
}

# ── Usuarios IAM ──────────────────────────────────────────────────────────────
output "publisher_user_arns" {
  description = "ARNs de los usuarios IAM con rol de publisher."
  value       = { for name, user in aws_iam_user.publisher : name => user.arn }
}

output "consumer_user_arns" {
  description = "ARNs de los usuarios IAM con rol de consumer."
  value       = { for name, user in aws_iam_user.consumer : name => user.arn }
}

# ── Comandos de verificacion rapida ──────────────────────────────────────────
output "verify_commands" {
  description = "Comandos de verificacion rapida para ejecutar tras el apply."
  value       = <<-EOT

    # ── Verificar el dominio ──────────────────────────────────────────────
    aws codeartifact describe-domain \
      --domain ${aws_codeartifact_domain.this.domain} \
      --region ${var.region} \
      --query "domain.{nombre:name,estado:status,cifrado:encryptionKey}"

    # ── Verificar el repositorio ──────────────────────────────────────────
    aws codeartifact describe-repository \
      --domain ${aws_codeartifact_domain.this.domain} \
      --repository ${aws_codeartifact_repository.this.repository} \
      --region ${var.region}

    # ── Obtener endpoint HTTPS del repositorio ────────────────────────────
    aws codeartifact get-repository-endpoint \
      --domain ${aws_codeartifact_domain.this.domain} \
      --domain-owner ${data.aws_caller_identity.current.account_id} \
      --repository ${aws_codeartifact_repository.this.repository} \
      --format generic \
      --region ${var.region} \
      --query repositoryEndpoint --output text

    # ── Listar paquetes publicados ────────────────────────────────────────
    aws codeartifact list-packages \
      --domain ${aws_codeartifact_domain.this.domain} \
      --repository ${aws_codeartifact_repository.this.repository} \
      --format generic \
      --region ${var.region}

    # ── Obtener token de autorizacion (valido 12 h) ───────────────────────
    aws codeartifact get-authorization-token \
      --domain ${aws_codeartifact_domain.this.domain} \
      --domain-owner ${data.aws_caller_identity.current.account_id} \
      --query authorizationToken --output text \
      --region ${var.region}
  EOT
}
