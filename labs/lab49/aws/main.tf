# Obtiene el ID de cuenta y el ARN del caller actual.
# Usado para construir ARNs de recursos y la política del bucket S3 de Config.
data "aws_caller_identity" "current" {}
