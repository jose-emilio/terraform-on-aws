output "cmk_key_id" {
  description = "Key ID de la CMK (UUID)"
  value       = aws_kms_key.main.key_id
}

output "cmk_key_arn" {
  description = "ARN completo de la CMK"
  value       = aws_kms_key.main.arn
}

output "cmk_alias_name" {
  description = "Nombre del alias de la CMK"
  value       = aws_kms_alias.main.name
}

output "cmk_alias_arn" {
  description = "ARN del alias de la CMK"
  value       = aws_kms_alias.main.arn
}

output "ebs_volume_id" {
  description = "ID del volumen EBS cifrado"
  value       = aws_ebs_volume.main.id
}

output "ebs_kms_key_id" {
  description = "Key ID usado por el volumen EBS"
  value       = aws_ebs_volume.main.kms_key_id
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.main.id
}

output "s3_bucket_arn" {
  description = "ARN del bucket S3"
  value       = aws_s3_bucket.main.arn
}

output "verify_cmk_command" {
  description = "Comando para describir la CMK y verificar la rotación"
  value       = "aws kms describe-key --key-id ${aws_kms_alias.main.name} --query 'KeyMetadata.{KeyId:KeyId,Enabled:Enabled,KeyRotationStatus:KeyRotationStatus}'"
}

output "verify_rotation_command" {
  description = "Comando para confirmar que la rotación automática está habilitada"
  value       = "aws kms get-key-rotation-status --key-id ${aws_kms_key.main.key_id}"
}

output "verify_ebs_encryption_command" {
  description = "Comando para confirmar el cifrado del volumen EBS"
  value       = "aws ec2 describe-volumes --volume-ids ${aws_ebs_volume.main.id} --query 'Volumes[0].{Encrypted:Encrypted,KmsKeyId:KmsKeyId}'"
}

output "verify_s3_encryption_command" {
  description = "Comando para confirmar la configuración SSE-KMS del bucket"
  value       = "aws s3api get-bucket-encryption --bucket ${aws_s3_bucket.main.id}"
}

output "test_encrypt_command" {
  description = "Comando para cifrar texto plano con la CMK (prueba de uso)"
  value       = "aws kms encrypt --key-id ${aws_kms_alias.main.name} --plaintext 'hola-lab13' --cli-binary-format raw-in-base64-out --query CiphertextBlob --output text"
}

output "test_upload_command" {
  description = "Comando para subir un objeto al bucket con cifrado KMS forzado"
  value       = "echo 'dato-secreto' | aws s3 cp - s3://${aws_s3_bucket.main.id}/test.txt --sse aws:kms --sse-kms-key-id ${aws_kms_alias.main.name}"
}
