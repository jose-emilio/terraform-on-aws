# Laboratorio 23 — LocalStack: Cimientos de EC2: Despliegue Dinamico y Seguro

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guia adapta el lab27 para ejecutarse integramente en LocalStack. La configuracion es identica a la de AWS real: data source `aws_ami`, IAM Instance Profile, Security Group e instancia EC2 con IMDSv2. Solo cambia el `providers.tf`.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
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
    iam = "http://localhost.localstack.cloud:4566"
    sts = "http://localhost.localstack.cloud:4566"
  }
}
```

> **Nota:** El data source `aws_ami` en LocalStack devuelve AMIs simuladas. El filtro se mantiene identico para validar la sintaxis, pero el ID devuelto no corresponde a una imagen real.

## 2. Despliegue

```bash
cd labs/lab27/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## 3. Verificacion

```bash
awslocal ec2 describe-instances --filters "Name=tag:Name,Values=corp-lab27-web"
awslocal iam list-instance-profiles
awslocal ec2 describe-security-groups --group-names corp-lab27-web-sg
```

## 4. Limpieza

```bash
terraform destroy
```

Consulta la guia principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
