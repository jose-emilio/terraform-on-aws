# El bucket S3 para almacenar el estado remoto fue creado y configurado en el Lab02
# con versionado, cifrado AES-256 y bloqueo de acceso público.
# Este proyecto solo crea la tabla DynamoDB para el bloqueo de estado (state locking)
# y demuestra cómo configurar el bloque backend "s3" apuntando a ese bucket.

# Tabla DynamoDB usada por Terraform para el bloqueo de estado (state locking).
# La Partition Key debe llamarse exactamente "LockID": es el nombre que el
# provider de AWS espera para identificar el registro de bloqueo.
# PAY_PER_REQUEST elimina la necesidad de aprovisionar capacidad de lectura/escritura.
resource "aws_dynamodb_table" "lock" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    ManagedBy = "terraform"
    Purpose   = "terraform-state-lock"
  }
}
