# Laboratorio 5 — LocalStack: Configuración Dinámica y Plantillas de Sistema

Esta guía adapta el lab05 para ejecutarse íntegramente en LocalStack. La configuración es idéntica a la de AWS real. `aws_key_pair`, `aws_launch_template` y `local_file` están soportados por LocalStack. Solo cambia el `providers.tf`.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- Par de claves SSH generado (`~/.ssh/id_rsa.pub`)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## 1. Diferencias con AWS

### `localstack/providers.tf`

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost.localstack.cloud:4566"
  }
}
```

## 2. Despliegue

```bash
cd labs/lab05/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## 3. Verificación

```bash
aws --profile localstack ec2 describe-key-pairs
aws --profile localstack ec2 describe-launch-templates
cat localstack/app.conf
```

## 4. Limpieza

```bash
terraform destroy
```

> El archivo `app.conf` generado por `local_file` también se elimina al hacer `destroy`.

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
