# secure-bucket

![Terraform on AWS](../../../../../images/lab-banner.svg)


Módulo Terraform que crea un bucket S3 con buenas prácticas de seguridad:
bloqueo de acceso público, versionado, cifrado y logging opcionales.

## Uso básico

```hcl
module "bucket" {
  source = "git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0"

  bucket_name = "mi-proyecto-data-123456789012"
  environment = "production"
}
```

## Uso avanzado

```hcl
module "bucket" {
  source = "git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0"

  bucket_name           = "mi-proyecto-data-123456789012"
  environment           = "production"
  enable_versioning     = true
  enable_encryption     = true
  enable_access_logging = true
  logging_target_bucket = "mi-proyecto-logs-123456789012"
  logging_target_prefix = "s3-access-logs/"

  tags = {
    Team = "platform"
  }
}
```

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
