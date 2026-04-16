# Laboratorio 11 — LocalStack: Gestión de Drift y Disaster Recovery

Esta guía adapta el lab11 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia reside en cómo se simula el drift y cómo se accede al bucket S3 de estado.

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

## 1. Despliegue inicial

```bash
cd labs/lab11/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Anota los outputs:

```bash
terraform output
# vpc_id           = "vpc-xxxxxxxxx"
# security_group_id = "sg-xxxxxxxxx"
```

## 2. Fase 1 — Simulación de Drift con awslocal

En LocalStack no hay consola web, por lo que el drift se simula directamente con la CLI.

### 2.1 Modificar un tag (cambio legítimo)

```bash
SG_ID=$(terraform output -raw security_group_id)

awslocal ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Environment,Value=production
```

### 2.2 Abrir un puerto (cambio accidental)

```bash
awslocal ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

### 2.3 Detectar el drift

```bash
terraform plan
```

El plan muestra **únicamente el cambio del tag**. La regla de ingreso del puerto 22 no aparece porque `aws_security_group` sin bloques `ingress` en el código no gestiona las reglas de ingreso.

## 3. Fase 2 — Reconciliación

### Opción A: Terraform gana (revertir el tag al estado deseado)

```bash
terraform apply
```

Terraform revierte el tag `Environment` a `"lab"`. La regla del puerto 22 permanece en AWS (no es gestionada por Terraform). Para eliminarla:

```bash
awslocal ec2 revoke-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

### Opción B: La realidad gana (actualizar el código para conservar el tag)

```bash
# Captura el estado real (tag "production" y regla puerto 22)
terraform apply -refresh-only
```

Edita `main.tf` para incorporar el tag actualizado:

```hcl
tags = {
  Name        = "app-lab11"
  Environment = "production"   # ← conservamos el cambio válido
  ManagedBy   = "terraform"
}
```

```bash
terraform apply
# No changes. Your infrastructure matches the configuration.
```

La regla del puerto 22 sigue en AWS. Para eliminarla usa CLI (ver Opción A).

## 4. Fase 3 — Disaster Recovery desde S3

### 4.1 Listar versiones del estado

```bash
awslocal s3api list-object-versions \
  --bucket terraform-state-labs \
  --prefix lab11/terraform.tfstate \
  --query 'Versions[*].[VersionId,LastModified]' \
  --output table
```

### 4.2 Simular corrupción del estado

```bash
# Guardar VersionId de la versión sana
GOOD_VERSION="<VersionId de la versión anterior>"

# Corromper el estado actual
echo '{"corrupted": true}' | awslocal s3 cp - s3://terraform-state-labs/lab11/terraform.tfstate
```

Verifica que el estado está corrupto:

```bash
terraform plan
# Error: Failed to read state...
```

### 4.3 Restaurar el estado sano

```bash
awslocal s3api copy-object \
  --bucket terraform-state-labs \
  --copy-source "terraform-state-labs/lab11/terraform.tfstate?versionId=$GOOD_VERSION" \
  --key lab11/terraform.tfstate
```

Verifica la restauración:

```bash
terraform plan
# No changes. Infrastructure matches configuration.
```

## 5. Limpieza

```bash
terraform destroy
```
