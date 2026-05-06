# Laboratorio 22 — LocalStack: Refactorización Avanzada de S3

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guia adapta el lab22 para ejecutarse integramente en LocalStack. S3 esta completamente soportado en LocalStack Community, por lo que la funcionalidad es practicamente identica. Las diferencias principales son: sin `prevent_destroy` (para facilitar limpieza) y sin bloqueo de acceso publico (emulacion parcial).

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- lab02/localstack desplegado (crea el bucket `terraform-state-labs` usado como backend de tfstate)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## Despliegue

```bash
cd labs/lab-22/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# logs_bucket_id  = "lab22-logs-000000000000"
# data_bucket_id  = "lab22-data-000000000000"
```

## Verificacion

### Listar buckets

```bash
awslocal s3 ls | grep lab22
# lab22-logs-000000000000
# lab22-data-000000000000
```

### Verificar etiquetas

```bash
LOGS_BUCKET=$(terraform output -raw logs_bucket_id)
DATA_BUCKET=$(terraform output -raw data_bucket_id)

awslocal s3api get-bucket-tagging --bucket $LOGS_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' --output table

awslocal s3api get-bucket-tagging --bucket $DATA_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' --output table
```

### Verificar versionado

```bash
awslocal s3api get-bucket-versioning --bucket $LOGS_BUCKET
# { "Status": "Suspended" }

awslocal s3api get-bucket-versioning --bucket $DATA_BUCKET
# { "Status": "Enabled" }
```

## Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| S3 Bucket | Completo | Completo |
| Versionado | Completo | Completo |
| Bloqueo acceso publico | Completo | Parcial |
| `prevent_destroy` | Funciona | Desactivado en esta version |
| SSE-KMS (Reto 2) | Completo | Parcial (sin cifrado real) |

## Limpieza

```bash
terraform destroy
```
