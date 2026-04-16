# Laboratorio 19 — LocalStack: Conectividad Punto a Punto con VPC Peering

Esta guia adapta el lab19 para ejecutarse integramente en LocalStack. LocalStack emula VPC Peering a nivel de API pero **no ejecuta trafico real**. El objetivo es validar la estructura de Terraform: VPCs, peerings, rutas bidireccionales y Security Groups.

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
cd labs/lab19/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# app_vpc_id       = "vpc-xxxxxxxxx"
# db_vpc_id        = "vpc-xxxxxxxxx"
# c_vpc_id         = "vpc-xxxxxxxxx"
# peering_app_db_id = "pcx-xxxxxxxxx"
# peering_app_c_id  = "pcx-xxxxxxxxx"
```

## 2. Verificacion

### 2.1 VPCs

```bash
awslocal ec2 describe-vpcs \
  --filters Name=tag:Project,Values=lab19 \
  --query 'Vpcs[].{Name: Tags[?Key==`Name`].Value|[0], CIDR: CidrBlock}' \
  --output table
```

### 2.2 Peerings

```bash
awslocal ec2 describe-vpc-peering-connections \
  --filters Name=tag:Project,Values=lab19 \
  --query 'VpcPeeringConnections[].{Name: Tags[?Key==`Name`].Value|[0], ID: VpcPeeringConnectionId, Status: Status.Code}' \
  --output table
```

### 2.3 Rutas con peering

```bash
awslocal ec2 describe-route-tables \
  --filters Name=tag:Project,Values=lab19 \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`].Value|[0], PeeringRoutes: Routes[?VpcPeeringConnectionId!=null].{Dest: DestinationCidrBlock, Peering: VpcPeeringConnectionId}}' \
  --output json
```

## 3. Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| VPC Peering | Tunel privado, trafico real | Emulado, sin trafico |
| Rutas con peering | Enrutan trafico real | Emuladas |
| No transitividad | Verificable con ping | No verificable sin trafico |
| Security Groups | Filtran trafico real | Emulados |
| Instancias EC2 | Ejecutan user_data | Emuladas |

Para verificar la no transitividad y la conectividad real, usa la version `aws/`.

## 4. Limpieza

```bash
terraform destroy
```
