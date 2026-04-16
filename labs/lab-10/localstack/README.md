# Laboratorio 10 — LocalStack: State Splitting (Capas de Infraestructura)

Este directorio contiene la versión LocalStack del laboratorio. La diferencia principal respecto a la versión AWS real está en el backend de estado y en la configuración del provider.

## Diferencias clave respecto a AWS real

| Aspecto | AWS real (`aws/`) | LocalStack (`localstack/`) |
|---|---|---|
| Backend de estado | S3 remoto (`backend "s3" {}`) | Local (`terraform.tfstate` en disco) |
| `terraform_remote_state` (cómputo) | `backend = "s3"` apunta a S3 | `backend = "local"` apunta a un archivo |
| Provider | Credenciales reales, endpoint AWS | Credenciales `test`, endpoint LocalStack |
| Creación de bucket previa | Requerida | No requerida |

El concepto de aislamiento de estados es idéntico en ambos casos: dos proyectos Terraform independientes, cada uno con su propio archivo de estado, que se comunican únicamente a través de `outputs` y `terraform_remote_state`.

---

## Prerrequisitos

```bash
localstack status   # LocalStack debe estar en ejecución
```

---

## 1. Capa de Red

### 1.1 Código (`localstack/network/`)

**`providers.tf`** — backend local, provider apuntando a LocalStack EC2:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # Sin bloque backend "s3": usa backend local por defecto.
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

**`main.tf`** — idéntico al de `aws/network/`: crea `aws_vpc.main` y `aws_subnet.public`.

**`outputs.tf`** — idéntico al de `aws/network/`: exporta `vpc_id`, `subnet_id` y `vpc_cidr`.

### 1.2 Despliegue

```bash
# Desde lab10/localstack/network/
terraform fmt
terraform init
terraform apply
```

El estado se guarda en `localstack/network/terraform.tfstate`. Verifica los outputs:

```bash
terraform output
```

Resultado esperado:

```
subnet_id = "subnet-xxxxxxxx"
vpc_cidr  = "10.0.0.0/16"
vpc_id    = "vpc-xxxxxxxx"
```

Verifica los recursos en LocalStack:

```bash
aws --endpoint-url=http://localhost.localstack.cloud:4566 ec2 describe-vpcs \
  --filters "Name=tag:Layer,Values=network" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table
```

---

## 2. Capa de Cómputo

### 2.1 Diferencia clave: `terraform_remote_state` con backend local

En la versión LocalStack, el data source usa `backend = "local"` en lugar de `backend = "s3"`:

```hcl
data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = var.network_state_path   # default: "../network/terraform.tfstate"
  }
}
```

La variable `network_state_path` apunta al archivo de estado de la capa de red usando una ruta relativa. No se necesita ninguna variable de bucket.

### 2.2 Despliegue

```bash
# Desde lab10/localstack/compute/
terraform fmt
terraform init
terraform apply
```

Verifica los outputs:

```bash
terraform output
```

Resultado esperado (con los IDs reales de LocalStack):

```
security_group_id = "sg-xxxxxxxx"
subnet_id         = "subnet-xxxxxxxx"
vpc_id            = "vpc-xxxxxxxx"
```

Nota que `vpc_id` y `subnet_id` coinciden exactamente con los outputs de la capa de red — son los mismos valores leídos desde el estado remoto, no copias hardcodeadas.

---

## 3. Verificación del Aislamiento (Blast Radius)

### 3.1 Destruir la capa de cómputo

```bash
# Desde lab10/localstack/compute/
terraform destroy
```

Terraform destruye únicamente el security group. La VPC sigue intacta en LocalStack.

### 3.2 Confirmar que la red no fue afectada

```bash
# Desde lab10/localstack/network/
terraform state list
# aws_subnet.public
# aws_vpc.main
```

El estado de la capa de red permanece intacto. La VPC nunca fue tocada por la destrucción de la capa de cómputo.

### 3.3 Verificar en LocalStack

```bash
aws --endpoint-url=http://localhost.localstack.cloud:4566 ec2 describe-vpcs \
  --filters "Name=tag:ManagedBy,Values=terraform" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table
```

La VPC sigue apareciendo. El blast radius de la destrucción de cómputo quedó contenido.

### 3.4 Redesplegar la capa de cómputo

```bash
# Desde lab10/localstack/compute/
terraform apply
```

El security group se crea de nuevo usando el mismo `vpc_id` que ya estaba en el estado de red. No hubo ningún cambio en la capa de red.

---

## 4. Destruir Todos los Recursos

Destruye en orden inverso: primero cómputo (que depende de red), luego red.

```bash
# Primero la capa de computo
cd lab10/localstack/compute/
terraform destroy

# Luego la capa de red
cd ../network/
terraform destroy
```
