# Laboratorio 2 — LocalStack: Bucket S3 como Backend de Estado

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab02 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia reside en la configuración del provider para redirigir las llamadas al endpoint local.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## 1. Código Terraform

**`localstack/main.tf`**

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "http://localhost.localstack.cloud:4566"
  }
}

resource "aws_s3_bucket" "state" {
  bucket = "terraform-state-labs"
  ...
}
```

Las diferencias clave respecto a la configuración de AWS real son:

| Parámetro | Valor | Propósito |
|---|---|---|
| `access_key` / `secret_key` | `test` | Credenciales ficticias aceptadas por LocalStack |
| `skip_credentials_validation` | `true` | Evita validar credenciales contra AWS STS |
| `skip_metadata_api_check` | `true` | Evita consultar el servicio de metadatos de EC2 |
| `skip_requesting_account_id` | `true` | Evita consultar el ID de cuenta real a AWS |
| `endpoints.s3` | URL de LocalStack | Redirige las llamadas de S3 a LocalStack |
| Nombre del bucket | `terraform-state-labs` (sin `<ACCOUNT_ID>`) | En LocalStack el nombre no necesita ser globalmente único |

## 2. Despliegue

```bash
cd labs/lab02/localstack

terraform init
terraform plan
terraform apply
```

> Aunque el código Terraform es casi idéntico al de AWS real, este directorio tiene su propio estado independiente en `terraform.tfstate`. Terraform no sabe nada del bucket creado en el otro directorio.

## 3. Verificación

Al finalizar `terraform apply`, Terraform mostrará los outputs:

```
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

Outputs:

bucket_arn    = "arn:aws:s3:::terraform-state-labs"
bucket_name   = "terraform-state-labs"
bucket_region = "us-east-1"
```

Verifica desde AWS CLI apuntando al perfil de LocalStack:

```bash
aws --profile localstack s3 ls
aws --profile localstack s3api get-bucket-versioning --bucket terraform-state-labs
```

## 4. Nota sobre Persistencia

> Los recursos de LocalStack **no persisten** entre reinicios del contenedor Docker. El lab07 recrea el bucket en LocalStack desde su propia configuración, por lo que no es necesario mantenerlo activo. El bucket de AWS real sí persiste y es el que se comparte entre laboratorios.

## 5. Limpieza

```bash
terraform destroy
```

Consulta la guía principal en [../README.md](../README.md) para los conceptos y el despliegue en AWS.
