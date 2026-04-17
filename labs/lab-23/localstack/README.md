# Laboratorio 19 — LocalStack: Diseño de Interfaz Robusta y "Fail-Safe"

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab23 para ejecutarse íntegramente en LocalStack. Los tres módulos (`safe-network`, `validated-bucket`, `db-config`) funcionan igual que en AWS real. Las validaciones, precondiciones y postcondiciones son evaluadas por el motor de Terraform, no por el proveedor, por lo que funcionan idénticamente. La diferencia principal es que `db-config` usa SSM SecureString en lugar de Secrets Manager.

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
cd labs/lab23/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply \
  -var="bucket_name=empresa-lab23-data-000000000000" \
  -var='db_password=MiPassword123Seguro'
```

Revisa los outputs:

```bash
terraform output
# vpc_id            = "vpc-..."
# vpc_cidr          = "10.19.0.0/16"
# bucket_id         = "empresa-lab23-data-000000000000"
# db_config_summary = { engine = "mysql", ... }
# ssm_prefix        = "/lab23/db/"
```

## 2. Verificación

### 2.1 Probar validaciones (funcionan igual que en AWS)

```bash
# Nombre sin prefijo → debe fallar
terraform plan -var="bucket_name=mi-bucket" -var='db_password=MiPassword123Seguro'
# Error: El nombre del bucket debe comenzar con 'empresa-'...

# Contraseña débil → debe fallar
terraform plan -var="bucket_name=empresa-test-bucket" -var='db_password=corta'
# Error: La contraseña debe tener al menos 12 caracteres.

# Motor inválido → debe fallar
terraform plan \
  -var="bucket_name=empresa-test-bucket" \
  -var='db_password=MiPassword123Seguro' \
  -var='db_config={"engine":"oracle","engine_version":"19c","instance_class":"db.m5.large","allocated_storage":50}'
# Error: El motor de base de datos debe ser uno de: mysql, postgres, mariadb.
```

### 2.2 Verificar recursos creados

```bash
# Bucket
awslocal s3 ls | grep empresa

# Parámetros SSM
awslocal ssm get-parameters-by-path \
  --path "/lab23/db/" \
  --query 'Parameters[].{Name: Name, Value: Value}' \
  --output table
```

## 3. Limitaciones en LocalStack

| Característica | AWS Real | LocalStack Community |
|---|---|---|
| `validation` en variables | Funciona | Funciona (evaluado por Terraform) |
| `postcondition` en recursos | Funciona | Funciona (evaluado por Terraform) |
| `precondition` en recursos | Funciona | Funciona (evaluado por Terraform) |
| `sensitive = true` | Oculta en plan/apply | Oculta en plan/apply |
| Secrets Manager | Completo | Emulación parcial |
| SSM SecureString | Cifrado con KMS | Sin cifrado real |
| VPC | Completa | Emulada |

## 4. Limpieza

```bash
terraform destroy \
  -var="bucket_name=empresa-lab23-data-000000000000" \
  -var='db_password=MiPassword123Seguro'
```
