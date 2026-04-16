# ── ECR ───────────────────────────────────────────────────────────────────────
output "ecr_repository_url" {
  description = "URL del repositorio ECR. Se usa como destino del 'docker push' y como valor de 'image' en el entorno de CodeBuild."
  value       = aws_ecr_repository.iac_runner.repository_url
}

output "ecr_repository_arn" {
  description = "ARN del repositorio ECR."
  value       = aws_ecr_repository.iac_runner.arn
}

# ── CodeCommit ────────────────────────────────────────────────────────────────
output "codecommit_repo_url_http" {
  description = "URL HTTPS del repositorio CodeCommit para git clone/push."
  value       = aws_codecommit_repository.terraform_code.clone_url_http
}

output "codecommit_repo_url_ssh" {
  description = "URL SSH del repositorio CodeCommit para git clone/push."
  value       = aws_codecommit_repository.terraform_code.clone_url_ssh
}

# ── S3 ────────────────────────────────────────────────────────────────────────
output "pipeline_bucket_name" {
  description = "Nombre del bucket S3 que almacena el codigo fuente y los artefactos del pipeline."
  value       = aws_s3_bucket.pipeline.bucket
}

output "pipeline_bucket_arn" {
  description = "ARN del bucket S3 del pipeline."
  value       = aws_s3_bucket.pipeline.arn
}

# ── CodeBuild ─────────────────────────────────────────────────────────────────
output "codebuild_project_name" {
  description = "Nombre del proyecto CodeBuild."
  value       = aws_codebuild_project.iac_runner.name
}

output "codebuild_project_arn" {
  description = "ARN del proyecto CodeBuild."
  value       = aws_codebuild_project.iac_runner.arn
}

output "codebuild_role_arn" {
  description = "ARN del rol IAM que usa CodeBuild."
  value       = aws_iam_role.codebuild.arn
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
output "log_group_name" {
  description = "Nombre del grupo de CloudWatch Logs donde CodeBuild escribe los logs de cada build."
  value       = aws_cloudwatch_log_group.codebuild.name
}

# ── Comandos utiles ───────────────────────────────────────────────────────────
output "build_commands" {
  description = "Comandos completos para construir la imagen, configurar el repo y usar el pipeline."
  value       = <<-EOT

    # ── Paso 1: Autenticarse con ECR ─────────────────────────────────────────
    aws ecr get-login-password --region ${var.region} \
      | docker login --username AWS --password-stdin \
          ${aws_ecr_repository.iac_runner.repository_url}

    # ── Paso 2: Construir la imagen con versiones pinneadas ───────────────────
    docker build \
      --build-arg TERRAFORM_VERSION=${var.terraform_version} \
      --build-arg TFLINT_VERSION=${var.tflint_version} \
      --build-arg TFSEC_VERSION=${var.tfsec_version} \
      --build-arg CHECKOV_VERSION=${var.checkov_version} \
      -t ${aws_ecr_repository.iac_runner.repository_url}:latest \
      Labs/Lab43/docker/

    # ── Paso 3: Publicar la imagen en ECR ────────────────────────────────────
    docker push ${aws_ecr_repository.iac_runner.repository_url}:latest

    # ── Paso 4: Clonar el repositorio CodeCommit y subir el codigo ───────────
    git clone ${aws_codecommit_repository.terraform_code.clone_url_http} /tmp/terraform-code
    cp -r Labs/Lab43/terraform-target/insecure/. /tmp/terraform-code/
    cp Labs/Lab43/buildspec.yml /tmp/terraform-code/
    cd /tmp/terraform-code
    git add . && git commit -m "feat: add insecure terraform code"
    git push origin main
    # El build se dispara automaticamente via EventBridge

    # ── Paso 5: Seguir los logs en tiempo real ────────────────────────────────
    aws logs tail ${aws_cloudwatch_log_group.codebuild.name} \
      --follow --region ${var.region}

    # ── Paso 6: Descargar el artefacto tfplan ────────────────────────────────
    BUILD_ID=$(aws codebuild list-builds-for-project \
      --project-name ${aws_codebuild_project.iac_runner.name} \
      --region ${var.region} \
      --query "ids[0]" --output text)
    BUILD_UUID=$${BUILD_ID#*:}
    aws s3 cp s3://${aws_s3_bucket.pipeline.bucket}/artifacts/$${BUILD_UUID}/plan /tmp/tfplan.zip
    unzip /tmp/tfplan.zip -d /tmp/tfplan-output/
  EOT
}
