# Laboratorio 16 — LocalStack: Red Multi-AZ Robusta y Dinámica

Esta guía adapta el lab16 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia reside en la configuración del provider y el backend.

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
cd labs/lab16/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# vpc_id             = "vpc-xxxxxxxxx"
# vpc_cidr           = "10.12.0.0/16"
# availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
# subnet_cidrs       = { "private-1" = "10.12.10.0/24", ... }
```

## 2. Verificación

### 2.1 VPC

```bash
awslocal ec2 describe-vpcs \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Vpcs[*].[VpcId,CidrBlock]' \
  --output table
```

### 2.2 Subredes

```bash
awslocal ec2 describe-subnets \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

### 2.3 Tags EKS

```bash
awslocal ec2 describe-subnets \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Subnets[].{Name: Tags[?Key==`Name`].Value|[0], ELB: Tags[?Key==`kubernetes.io/role/elb`].Value|[0], InternalELB: Tags[?Key==`kubernetes.io/role/internal-elb`].Value|[0], Cluster: Tags[?Key==`kubernetes.io/cluster/lab16`].Value|[0]}' \
  --output table
```

## 3. Probar la postcondición

Intenta desplegar con un CIDR no RFC 1918:

```bash
terraform apply -var="vpc_cidr=203.0.113.0/24"
```

Terraform rechazará el plan con el error de la postcondición.

> **Nota:** En LocalStack la postcondición se evalúa igual que en AWS real, ya que es una validación del lado de Terraform, no del proveedor.

## 4. Limpieza

```bash
terraform destroy
```
