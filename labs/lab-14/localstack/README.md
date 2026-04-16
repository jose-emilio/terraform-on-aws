# Laboratorio 14 — LocalStack: Automatización de Secretos "Zero-Touch"

Entorno local con LocalStack para practicar los recursos KMS, Secrets Manager y
`random_password` del laboratorio sin necesidad de una cuenta de AWS.

> Para la guía completa (conceptos, arquitectura, retos y buenas prácticas)
> consulta el [README principal](../README.md).

## Limitaciones respecto a AWS real

| Característica | LocalStack Community | LocalStack Pro |
|----------------|---------------------|----------------|
| KMS (CMK + alias + rotación) | Emulado | Emulado (más completo) |
| Secrets Manager (cifrado con CMK) | Funcional (sin cifrado KMS real) | Funcional |
| `random_password` | Funcional | Funcional |
| RDS (instancia, subnet group, security group) | **Omitido** — requiere licencia Pro | Emulado |
| Backend KMS para `.tfstate` | Sin cifrado real | Sin cifrado real |

En LocalStack Community se omiten todos los recursos RDS y de red asociados
(`aws_db_instance`, `aws_db_subnet_group`, `aws_vpc`, `aws_subnet`,
`aws_security_group`). El `secret_string` usa `host = "localhost"` como
placeholder en lugar del endpoint real de RDS.

El hardening del backend con KMS requiere AWS real para validarse correctamente.

## Requisitos previos

- LocalStack CLI instalado y Docker en ejecución.
- Terraform ≥ 1.5.
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566
```

## Despliegue

```bash
# Arrancar LocalStack
localstack start -d

cd labs/lab14/localstack
terraform init -backend-config=localstack.s3.tfbackend
terraform plan
terraform apply
```

## Verificación en LocalStack

### CMK y alias

```bash
aws kms list-aliases \
  --query 'Aliases[?AliasName==`alias/lab14-secrets`]'

aws kms describe-key \
  --key-id alias/lab14-secrets \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Description:Description}'

aws kms get-key-rotation-status \
  --key-id $(terraform output -raw kms_key_arn)
# Nota: get-key-rotation-status no acepta alias, requiere Key ID (UUID) o ARN
# Esperado: { "KeyRotationEnabled": true }
```

### Secreto en Secrets Manager

```bash
# Recuperar el valor del secreto (JSON con los datos de conexión)
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw secret_name) \
  --query SecretString --output text | python3 -m json.tool
# Esperado: JSON con username, password (32 chars), engine, port, dbname

# Confirmar que el secreto está asociado a la CMK
aws secretsmanager describe-secret \
  --secret-id $(terraform output -raw secret_name) \
  --query '{Name:Name,KmsKeyId:KmsKeyId}'
```

### Confirmar que la contraseña no aparece en el plan

```bash
terraform plan
```

Busca `password = (sensitive value)` — confirma que `random_password` protege
el valor de la visualización directa incluso en LocalStack.

## Limpieza

```bash
terraform destroy
localstack stop   # opcional
```
