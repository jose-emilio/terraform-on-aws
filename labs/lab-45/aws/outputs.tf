output "pipeline_url" {
  description = "URL de la consola de AWS del pipeline."
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.main.name}/view"
}

output "repository_clone_url_https" {
  description = "URL HTTPS para clonar el repositorio CodeCommit."
  value       = aws_codecommit_repository.terraform.clone_url_http
}

output "repository_clone_url_ssh" {
  description = "URL SSH para clonar el repositorio CodeCommit."
  value       = aws_codecommit_repository.terraform.clone_url_ssh
}

output "artifact_bucket" {
  description = "Nombre del bucket S3 que almacena los artefactos del pipeline y el estado de Terraform."
  value       = aws_s3_bucket.artifacts.bucket
}

output "approval_topic_arn" {
  description = "ARN del topic SNS al que CodePipeline publica la solicitud de aprobacion manual."
  value       = aws_sns_topic.approvals.arn
}

output "plan_inspector_function_name" {
  description = "Nombre de la funcion Lambda inspectora del plan de Terraform."
  value       = aws_lambda_function.plan_inspector.function_name
}

output "kms_key_arn" {
  description = "ARN de la CMK KMS usada para cifrar los artefactos del pipeline."
  value       = aws_kms_key.artifacts.arn
}
