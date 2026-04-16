# Laboratorio 17 — LocalStack: Optimización de Salida a Internet y "NAT Tax"

Esta guía adapta el lab17 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia principal es que **la Instancia NAT no está disponible** (requiere AMIs reales de EC2), por lo que solo se despliega la variante con NAT Gateway.

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
cd labs/lab17/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# vpc_id               = "vpc-xxxxxxxxx"
# internet_gateway_id  = "igw-xxxxxxxxx"
# nat_gateway_id       = "nat-xxxxxxxxx"
# s3_endpoint_id       = "vpce-xxxxxxxxx"
```

## 2. Verificación

### 2.1 Internet Gateway

```bash
awslocal ec2 describe-internet-gateways \
  --filters Name=tag:Project,Values=lab17 \
  --query 'InternetGateways[].{ID: InternetGatewayId, VPC: Attachments[0].VpcId}' \
  --output table
```

### 2.2 NAT Gateway

```bash
awslocal ec2 describe-nat-gateways \
  --filter Name=tag:Project,Values=lab17 \
  --query 'NatGateways[].{ID: NatGatewayId, State: State, SubnetId: SubnetId}' \
  --output table
```

### 2.3 Tablas de rutas

```bash
# Tabla pública: 0.0.0.0/0 → IGW
awslocal ec2 describe-route-tables \
  --filters Name=tag:Name,Values=lab17-public-rt \
  --query 'RouteTables[].Routes[].{Dest: DestinationCidrBlock, GatewayId: GatewayId, NatGatewayId: NatGatewayId}' \
  --output table

# Tabla privada: 0.0.0.0/0 → NAT GW + prefijo S3 → VPC Endpoint
awslocal ec2 describe-route-tables \
  --filters Name=tag:Name,Values=lab17-private-rt \
  --query 'RouteTables[].Routes[].{Dest: DestinationCidrBlock, Prefix: DestinationPrefixListId, GatewayId: GatewayId, NatGatewayId: NatGatewayId}' \
  --output table
```

### 2.4 VPC Endpoint para S3

```bash
awslocal ec2 describe-vpc-endpoints \
  --filters Name=tag:Project,Values=lab17 \
  --query 'VpcEndpoints[].{ID: VpcEndpointId, Service: ServiceName, State: State, RouteTables: RouteTableIds}' \
  --output table
```

## 3. Limitaciones en LocalStack

| Característica | AWS Real | LocalStack |
|---|---|---|
| NAT Gateway | Funcional, procesa tráfico | Emulado, sin tráfico real |
| NAT Instance | AL2023 ARM + iptables user_data | No disponible (requiere AMI real) |
| VPC Endpoint S3 | Ruta real al servicio S3 | Emulado |
| Cargos NAT | $0.045/GB procesado | Sin cargos |

Para probar la Instancia NAT, usa la versión `aws/` con `-var="use_nat_instance=true"`.

## 4. Limpieza

```bash
terraform destroy
```
