# Laboratorio 6 — LocalStack: Auditoría Dinámica y Conectividad Externa

Esta guía adapta el lab06 para ejecutarse íntegramente en LocalStack. En LocalStack no existe infraestructura previa, por lo que `localstack/main.tf` crea los recursos necesarios para que cada data source tenga algo que consultar.

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

### `localstack/main.tf`

En LocalStack se crean los recursos de prueba y se usa `depends_on` para que los data sources esperen a que existan:

```hcl
# VPC de prueba con el tag correcto
resource "aws_vpc" "production" {
  cidr_block = "10.0.0.0/16"
  tags       = { Env = var.target_env }
}

data "aws_vpc" "production" {
  filter {
    name   = "tag:Env"
    values = [var.target_env]
  }
  depends_on = [aws_vpc.production]
}

# LocalStack no incluye políticas gestionadas de AWS; se crea una de prueba
resource "aws_iam_policy" "read_only" {
  name   = "ReadOnlyAccess"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["*"], Resource = ["*"] }]
  })
}

data "aws_iam_policy" "read_only" {
  name       = "ReadOnlyAccess"
  depends_on = [aws_iam_policy.read_only]
}

# aws_instances devolverá lista vacía; la plantilla lo gestiona con %{if}
data "aws_instances" "production" { ... }
```

## 2. Despliegue

```bash
cd labs/lab06/localstack

terraform fmt
terraform init
terraform plan
terraform apply
```

## 3. Verificación

```bash
cat localstack/audit_report.txt
terraform output caller_arn
aws --profile localstack ec2 describe-vpcs --filters "Name=tag:Env,Values=production"
aws --profile localstack iam get-policy --policy-arn arn:aws:iam::000000000000:policy/ReadOnlyAccess
```

## 4. Limpieza

```bash
terraform destroy
```

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
