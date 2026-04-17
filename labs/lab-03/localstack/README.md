# Laboratorio 3 — LocalStack: Infraestructura Parametrizada y Dinámica

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab03 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia reside en la configuración del provider.

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

`variables.tf`, `main.tf` y `outputs.tf` son idénticos a los de `aws/`. El único fichero que cambia es `providers.tf`.

**`localstack/providers.tf`**

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

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

A diferencia del lab02 donde se redirigía `s3`, aquí se redirige `ec2` porque VPC, subredes y security groups son recursos del servicio EC2 de AWS.

## 2. Despliegue

```bash
cd labs/lab03/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## 3. Verificación

```bash
aws --profile localstack ec2 describe-vpcs
aws --profile localstack ec2 describe-subnets
aws --profile localstack ec2 describe-security-groups
```

## 4. Limpieza

```bash
terraform destroy
```

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
