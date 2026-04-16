output "oidc_provider_arn" {
  description = "ARN del proveedor OIDC de GitHub Actions"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_role_arn" {
  description = "ARN del rol que asume GitHub Actions via OIDC - usar en el workflow como role-to-assume"
  value       = aws_iam_role.github_actions.arn
}

output "github_actions_role_name" {
  description = "Nombre del rol IAM para GitHub Actions"
  value       = aws_iam_role.github_actions.name
}
