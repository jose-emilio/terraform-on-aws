# Laboratorio 18 — LocalStack: Refactorizacion Avanzada de S3

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guia adapta el lab22 para ejecutarse integramente en LocalStack. S3 esta completamente soportado en LocalStack Community, por lo que la funcionalidad es practicamente identica. Las diferencias principales son: sin `prevent_destroy` (para facilitar limpieza) y sin bloqueo de acceso publico (emulacion parcial).

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- lab07/localstack desplegado (crea bucket `terraform-state-labs`)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## 1. Despliegue

```bash
cd labs/lab22/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# logs_bucket_id  = "lab22-logs-000000000000"
# data_bucket_id  = "lab22-data-000000000000"
```

## 2. Verificacion

### 2.1 Listar buckets

```bash
awslocal s3 ls | grep lab18
# lab22-logs-000000000000
# lab22-data-000000000000
```

### 2.2 Verificar etiquetas

```bash
LOGS_BUCKET=$(terraform output -raw logs_bucket_id)
DATA_BUCKET=$(terraform output -raw data_bucket_id)

awslocal s3api get-bucket-tagging --bucket $LOGS_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' --output table

awslocal s3api get-bucket-tagging --bucket $DATA_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' --output table
```

### 2.3 Verificar versionado

```bash
awslocal s3api get-bucket-versioning --bucket $LOGS_BUCKET
# { "Status": "Suspended" }

awslocal s3api get-bucket-versioning --bucket $DATA_BUCKET
# { "Status": "Enabled" }
```

## 3. Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| S3 Bucket | Completo | Completo |
| Versionado | Completo | Completo |
| Bloqueo acceso publico | Completo | Parcial |
| `prevent_destroy` | Funciona | Desactivado en esta version |
| SSE-KMS (Reto 2) | Completo | Parcial (sin cifrado real) |

## 4. Limpieza

```bash
terraform destroy
```
