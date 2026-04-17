# Laboratorio 4 — LocalStack: Orquestación de Identidades y Gestión de Ciclo de Vida

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab04 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; las diferencias principales son el provider y la ausencia del data source `aws_ami`.

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

LocalStack soporta IAM y EC2 (incluyendo launch templates), pero el data source `aws_ami` no devuelve resultados reales ya que no hay un catálogo de AMIs. Por eso, en el entorno local se sustituye por una AMI ficticia hardcodeada y se omite el output correspondiente.

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
    iam = "http://localhost.localstack.cloud:4566"
    ec2 = "http://localhost.localstack.cloud:4566"
    sts = "http://localhost.localstack.cloud:4566"
  }
}
```

Se añade `sts` porque `aws_caller_identity` llama al servicio STS para obtener la identidad activa.

### Diferencias en `localstack/main.tf`

Se elimina el data source `aws_ami` y se usa una AMI ficticia:

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  image_id      = "ami-00000000000000000"  # AMI ficticia para LocalStack
  instance_type = "t3.micro"

  lifecycle {
    create_before_destroy = true
  }
  ...
}
```

## 2. Despliegue

```bash
cd labs/lab04/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## 3. Verificación

```bash
aws --profile localstack iam list-users
aws --profile localstack ec2 describe-launch-templates
aws --profile localstack sts get-caller-identity
```

## 4. Limpieza

```bash
terraform destroy
```

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
