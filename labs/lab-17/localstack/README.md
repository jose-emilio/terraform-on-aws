# Laboratorio 17 — LocalStack: Optimización de Salida a Internet y "NAT Tax"

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab17 para ejecutarse íntegramente en LocalStack. Los conceptos son idénticos a la versión AWS; la diferencia principal es que **la Instancia NAT no está disponible** (requiere AMIs reales de EC2), por lo que solo se despliega la variante con NAT Gateway.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- lab02/localstack desplegado (crea el bucket `terraform-state-labs` usado como backend de tfstate)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## Despliegue

```bash
cd labs/lab-17/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# vpc_id                  = "vpc-xxxxxxxxx"
# internet_gateway_id     = "igw-xxxxxxxxx"
# nat_gateway_ids         = { "public-1" = "nat-xxxxxxxxx", ... }
# nat_public_ips          = { "public-1" = "x.x.x.x", ... }
# s3_endpoint_id          = "vpce-xxxxxxxxx"
# private_subnet_ids      = { "private-1" = "subnet-xxx", ... }
# private_route_table_ids = { "private-1" = "rtb-xxx", ... }
```

## Verificación

### Internet Gateway

```bash
awslocal ec2 describe-internet-gateways \
  --filters Name=tag:Project,Values=lab17 \
  --query 'InternetGateways[].{ID: InternetGatewayId, VPC: Attachments[0].VpcId}' \
  --output table
```

### NAT Gateway

```bash
awslocal ec2 describe-nat-gateways \
  --filter Name=tag:Project,Values=lab17 \
  --query 'NatGateways[].{ID: NatGatewayId, State: State, SubnetId: SubnetId}' \
  --output table
```

### Tablas de rutas

```bash
# Tabla pública: 0.0.0.0/0 → IGW
awslocal ec2 describe-route-tables \
  --filters Name=tag:Name,Values=lab17-public-rt \
  --query 'RouteTables[].Routes[].{Dest: DestinationCidrBlock, GatewayId: GatewayId, NatGatewayId: NatGatewayId}' \
  --output table

# Tablas privadas (una por AZ): 0.0.0.0/0 → NAT GW + prefijo S3 → VPC Endpoint
awslocal ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=lab17-private-rt-*" \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`].Value|[0], Routes: Routes[].{Dest: DestinationCidrBlock, Prefix: DestinationPrefixListId, GatewayId: GatewayId, NatGatewayId: NatGatewayId}}' \
  --output json
```

### VPC Endpoint para S3

```bash
awslocal ec2 describe-vpc-endpoints \
  --filters Name=tag:Project,Values=lab17 \
  --query 'VpcEndpoints[].{ID: VpcEndpointId, Service: ServiceName, State: State, RouteTables: RouteTableIds}' \
  --output table
```

## Instancia de test

Igual que en la versión aws/, este lab despliega una `aws_instance.test` en
`private-1` con un Security Group que solo permite tráfico saliente (`ingress = []`
explícito). En LocalStack esta instancia no ejecuta tráfico real — su único
propósito es validar la estructura Terraform: que el SG, las dependencias del
NAT Gateway y la asociación de subred privada se declaren correctamente.

```bash
awslocal ec2 describe-instances \
  --filters Name=tag:Project,Values=lab17 \
  --query 'Reservations[].Instances[].{ID: InstanceId, AZ: Placement.AvailabilityZone, SubnetId: SubnetId}' \
  --output table
```

## Limitaciones en LocalStack

| Característica | AWS Real | LocalStack |
|---|---|---|
| NAT Gateway | Funcional, procesa tráfico | Emulado, sin tráfico real |
| NAT Instance | AL2023 ARM + iptables user_data | No disponible (requiere AMI real) |
| Instancia de test | Conectividad real verificable por SSM | Emulada, sin SSM ni tráfico |
| VPC Endpoint S3 | Ruta real al servicio S3 | Emulado |
| Cargos NAT | $0.045/GB procesado | Sin cargos |

Para probar la Instancia NAT, usa la versión `aws/` con `-var="use_nat_instance=true"`.

## Limpieza

```bash
terraform destroy
```
