# Laboratorio 27 — LocalStack: Cimientos de EC2: Despliegue Dinámico y Seguro

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab27 para ejecutarse íntegramente en LocalStack. La configuración es idéntica a la de AWS real: data source `aws_ami`, IAM Instance Profile, Security Group e instancia EC2 con IMDSv2. Sólo cambia el `providers.tf`.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## Diferencias con AWS

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

> **Nota:** El data source `aws_ami` en LocalStack devuelve AMIs simuladas. El filtro se mantiene idéntico para validar la sintaxis, pero el ID devuelto no corresponde a una imagen real.

## Despliegue

```bash
cd labs/lab-27/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## Verificación

```bash
awslocal ec2 describe-instances --filters "Name=tag:Name,Values=corp-lab27-web"
awslocal iam list-instance-profiles
awslocal ec2 describe-security-groups --group-names corp-lab27-web-sg
```

## Limpieza

```bash
terraform destroy
```

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
