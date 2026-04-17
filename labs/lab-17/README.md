# Laboratorio 17 — Optimización de Salida a Internet y "NAT Tax"

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Configurar la conectividad de salida a Internet priorizando la **alta disponibilidad** y la **eficiencia de costes** (FinOps), comparando el modelo NAT Gateway regional con una Instancia NAT EC2 para entornos de desarrollo.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Internet Gateway (IGW)** | Componente de VPC que permite comunicación bidireccional entre subredes públicas e Internet; sin coste base, sin límite de ancho de banda |
| **NAT Gateway** | Servicio gestionado que permite a las subredes privadas iniciar conexiones salientes a Internet sin exponerse; coste: ~$32/mes + $0.045/GB procesado |
| **NAT Gateway × 3 AZs** | Buena práctica: 1 NAT Gateway por AZ elimina tráfico cross-AZ y mantiene la salida si cae una AZ |
| **Instancia NAT** | EC2 ARM configurada como router NAT con iptables; coste: ~$12.26/mes (t4g.small), ahorro ~62% vs NAT Gateway, mejor relación precio/rendimiento en Graviton |
| **`source_dest_check`** | Atributo de EC2 que por defecto descarta tráfico cuyo origen/destino no sea la propia instancia; **debe deshabilitarse** en instancias NAT |
| **VPC Gateway Endpoint** | Ruta directa desde la VPC al servicio de AWS (S3, DynamoDB) por la red interna; **completamente gratuito**, evita el cargo por GB del NAT |
| **"NAT Tax"** | Término coloquial para el coste acumulado de $0.045/GB que cobra el NAT Gateway por cada GB procesado; puede ser significativo en cargas con alto volumen de datos |

## Comparativa de costes

| Modelo | Coste base (mes) | Coste por GB | Alta disponibilidad | Mantenimiento |
|---|---|---|---|---|
| NAT Gateway × 3 AZs (este lab) | ~$96 | $0.045 | Sí (por AZ) | Ninguno |
| Instancia NAT × 3 AZs (este lab) | ~$36.78 | Tráfico EC2 estándar | Sí (por AZ) | Parches, iptables, monitoreo |
| VPC Endpoint S3 | $0 | $0 | Sí | Ninguno |

> **Regla FinOps:** Usa NAT Gateway × 3 en producción (alta disponibilidad sin mantenimiento), Instancia NAT × 3 en dev/sandbox (ahorro ~62%), y **siempre** VPC Endpoints para servicios de AWS de alto volumen (S3, DynamoDB).

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- lab07/aws desplegado (bucket S3 con versionado habilitado)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab17/
├── README.md                    ← Esta guía
├── aws/
│   ├── providers.tf             ← Backend S3 parcial
│   ├── variables.tf             ← Variables: región, CIDR, proyecto, use_nat_instance
│   ├── main.tf                  ← VPC + subredes + IGW + NAT GW/Instance + VPC Endpoint S3
│   ├── outputs.tf               ← IDs, IPs, modo NAT activo
│   └── aws.s3.tfbackend         ← Parámetros del backend (sin bucket)
└── localstack/
    ├── README.md                ← Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                  ← Solo NAT Gateway (NAT Instance no disponible en LocalStack)
    ├── outputs.tf
    └── localstack.s3.tfbackend  ← Backend completo para LocalStack
```

## 1. Análisis del código

### 1.1 Internet Gateway — La puerta de entrada

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}
```

El IGW es el componente más simple de la red: se adjunta a la VPC y permite que las subredes públicas (con una ruta `0.0.0.0/0 → igw`) se comuniquen bidireccionalmente con Internet. No tiene coste base ni límite de ancho de banda.

Las subredes públicas se asocian a una tabla de rutas con esta ruta:

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

### 1.2 NAT Gateway × 3 — Uno por AZ (buena práctica)

```hcl
resource "aws_nat_gateway" "this" {
  for_each = var.use_nat_instance ? {} : {
    for idx, az in local.azs : az => "public-${idx + 1}"
  }

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.value].id

  depends_on = [aws_internet_gateway.main]
}
```

Puntos clave:
- Se despliega **un NAT Gateway por AZ**, cada uno en la subred pública correspondiente
- `for_each` itera sobre las AZs: la clave es el nombre de la AZ, el valor es la subred pública
- Cada NAT Gateway tiene su propia **Elastic IP** (3 EIPs en total)
- `depends_on` asegura que el IGW exista antes de crear los NAT Gateways

**¿Por qué 1 por AZ en vez de 1 compartido?**

| Aspecto | 1 NAT GW compartido | 1 NAT GW por AZ (este lab) |
|---|---|---|
| Coste base | ~$32/mes | ~$96/mes |
| Tráfico cross-AZ | Sí ($0.01/GB extra) | No |
| Resiliencia | Si cae la AZ, **todas** las privadas pierden salida | Solo la AZ afectada pierde salida |
| Buena práctica AWS | No | **Sí** |

A escala, el coste de tráfico cross-AZ puede superar la diferencia de $64/mes. La resiliencia adicional suele justificar el coste en producción.

### 1.3 Tablas de rutas privadas — Una por AZ

```hcl
resource "aws_route_table" "private" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.main.id
}

resource "aws_route_table_association" "private" {
  for_each       = local.private_subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[local.azs[each.value.az_index]].id
}
```

Cada subred privada se asocia a la tabla de rutas de **su propia AZ**, que apunta al NAT local. Esto garantiza que el tráfico nunca cruza AZs para salir a Internet.

### 1.4 Instancia NAT × 3 — La alternativa económica para desarrollo

```hcl
resource "aws_instance" "nat" {
  for_each = var.use_nat_instance ? {
    for idx, az in local.azs : az => "public-${idx + 1}"
  } : {}

  ami                    = data.aws_ami.nat.id   # AL2023 ARM minimal
  instance_type          = "t4g.small"            # Graviton (ARM)
  subnet_id              = aws_subnet.this[each.value].id
  vpc_security_group_ids = [aws_security_group.nat[0].id]

  source_dest_check = false  # ← CLAVE para NAT

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    dnf install -y iptables-nft
    iptables -t nat -A POSTROUTING -o ens5 -s ${var.vpc_cidr} -j MASQUERADE
    iptables -A FORWARD -i ens5 -o ens5 -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i ens5 -o ens5 -j ACCEPT
    service iptables save
  EOT
}
```

Mismo patrón `for_each` que los NAT Gateways: una instancia por AZ en su subred pública correspondiente.

**¿Por qué `t4g.small` ARM en vez de `t3.nano` x86?**

Las instancias Graviton (t4g) ofrecen hasta un 20% mejor relación precio/rendimiento que las equivalentes x86. Para una instancia NAT, el cuello de botella es el ancho de banda de red, no la CPU, y `t4g.small` proporciona suficiente capacidad de red para un entorno de desarrollo.

**¿Por qué `user_data` con iptables?**

Las antiguas AMIs `amzn-ami-vpc-nat` venían preconfiguradas con NAT, pero están basadas en Amazon Linux 1 (EOL). Usamos Amazon Linux 2023 (ARM) y configuramos NAT manualmente:

1. **`ip_forward = 1`**: Habilita el reenvío de paquetes en el kernel (por defecto Linux descarta paquetes que no son para él)
2. **`iptables -t nat ... MASQUERADE`**: Reescribe la IP origen de los paquetes reenviados con la IP pública de la instancia, permitiendo que las respuestas vuelvan correctamente
3. **`FORWARD ... RELATED,ESTABLISHED`**: Permite el tráfico de retorno de conexiones ya establecidas

**¿Por qué `source_dest_check = false`?**

Por defecto, EC2 descarta cualquier paquete de red cuyo origen o destino no sea la IP de la propia instancia. Esto es una protección contra suplantación de IP. Pero una instancia NAT **reenvía** tráfico de otros orígenes (las subredes privadas), por lo que esta verificación debe deshabilitarse.

Sin `source_dest_check = false`, el tráfico de las subredes privadas llega a la instancia NAT pero es descartado silenciosamente — uno de los errores más difíciles de diagnosticar en redes AWS.

### 1.5 VPC Gateway Endpoint para S3 — Eliminar el "NAT Tax"

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]
}
```

El Gateway Endpoint añade automáticamente una ruta en las tablas especificadas con el **prefix list** de S3 (las IPs del servicio S3 en la región). El tráfico hacia S3 viaja por la red interna de AWS en lugar de salir por el NAT Gateway.

**Impacto en costes:** Si una aplicación transfiere 100 GB/mes a S3:
- Sin endpoint: 100 GB × $0.045 = **$4.50/mes** en cargos NAT
- Con endpoint: **$0** — el tráfico no pasa por el NAT

A escala (TB de datos, backups, logs), este ahorro puede ser de cientos de dólares mensuales.

### 1.6 Rutas privadas mutuamente excluyentes — Una por AZ

```hcl
resource "aws_route" "private_nat_gateway" {
  for_each = var.use_nat_instance ? {} : toset(local.azs)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}

resource "aws_route" "private_nat_instance" {
  for_each = var.use_nat_instance ? toset(local.azs) : toset([])

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id
}
```

Solo uno de los dos conjuntos existe en cada despliegue. En ambos casos se crean 3 rutas `0.0.0.0/0` (una por tabla de rutas privada), cada una apuntando al NAT Gateway o la instancia NAT de **su misma AZ**.

---

## 2. Despliegue — Modo producción (NAT Gateway)

```bash
cd labs/lab17/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Terraform creará ~25 recursos: VPC, 6 subredes, IGW, 3 EIPs, 3 NAT Gateways, 1 tabla de rutas pública + 3 privadas (una por AZ), rutas, asociaciones, VPC Endpoint, IAM role SSM.

```bash
terraform output
# nat_mode       = "nat_gateway"
# nat_public_ips = { "us-east-1a" = "3.xx.xx.xx", "us-east-1b" = "18.xx.xx.xx", "us-east-1c" = "54.xx.xx.xx" }
# s3_endpoint_id = "vpce-0abc..."
```

---

## Verificación final

### 3.1 Tabla de rutas pública

```bash
aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values=lab17-public-rt \
  --query 'RouteTables[].Routes[].{Dest: DestinationCidrBlock, GatewayId: GatewayId}' \
  --output table
```

Deberías ver:
- `10.13.0.0/16 → local` (ruta interna de la VPC, automática)
- `0.0.0.0/0 → igw-xxx` (ruta al IGW)

### 3.2 Tablas de rutas privadas (una por AZ)

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=lab17-private-rt-*" \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`].Value|[0], Routes: Routes[].{Dest: DestinationCidrBlock, Prefix: DestinationPrefixListId, NatGW: NatGatewayId, GatewayId: GatewayId}}' \
  --output json
```

Cada tabla debe tener:
- `10.13.0.0/16 → local`
- `0.0.0.0/0 → nat-xxx` (ruta al NAT Gateway **de su propia AZ**)
- `pl-xxx → vpce-xxx` (prefix list de S3 → VPC Endpoint)

Verifica que cada tabla privada apunta a un NAT Gateway **diferente** (uno por AZ).

### 3.3 VPC Endpoint

```bash
aws ec2 describe-vpc-endpoints \
  --filters Name=tag:Project,Values=lab17 \
  --query 'VpcEndpoints[].{ID: VpcEndpointId, Service: ServiceName, State: State}' \
  --output table
```

### 3.4 Verificar el prefix list de S3

```bash
PLID=$(aws ec2 describe-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.us-east-1.s3 \
  --query 'PrefixLists[0].PrefixListId' --output text)

aws ec2 describe-prefix-lists \
  --prefix-list-ids $PLID \
  --query 'PrefixLists[].Cidrs[]' \
  --output table
```

Estos son los rangos IP de S3 que el Gateway Endpoint intercepta antes de que lleguen al NAT.

---

## 4. Despliegue — Modo desarrollo (Instancia NAT)

Destruye el despliegue anterior y redespliega con la instancia NAT:

```bash
terraform destroy -var="region=us-east-1"

terraform apply -var="use_nat_instance=true"
```

Compara los outputs:

```bash
terraform output
# nat_mode       = "nat_instance"
# nat_public_ips = { "us-east-1a" = "54.xx.xx.xx", "us-east-1b" = "3.xx.xx.xx", "us-east-1c" = "18.xx.xx.xx" }
```

### 4.1 Verificar source_dest_check en las 3 instancias

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=nat-instance-lab17-*" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{ID: InstanceId, AZ: Placement.AvailabilityZone, SourceDestCheck: SourceDestCheck}' \
  --output table
```

Las 3 instancias deben mostrar `SourceDestCheck = false`.

### 4.2 Verificar las tablas de rutas privadas

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=lab17-private-rt-*" \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`].Value|[0], Routes: Routes[].{Dest: DestinationCidrBlock, Prefix: DestinationPrefixListId, NetworkInterface: NetworkInterfaceId, GatewayId: GatewayId}}' \
  --output json
```

Ahora cada ruta `0.0.0.0/0` apunta a `eni-xxx` (la interfaz de red de la instancia NAT de esa AZ) en lugar de `nat-xxx`.

---

## 5. Verificacion end-to-end con instancia de test

La instancia de test se despliega automáticamente en la subred `private-1` con cada `terraform apply`. Es una `t4g.micro` con SSM Agent, que permite verificar la conectividad NAT sin SSH.

```bash
terraform output test_instance_id
# "i-0abc123..."
```

### 5.1 Conectarse via SSM Session Manager

> **Requisito:** Instalar el [plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) para la AWS CLI.

```bash
INSTANCE_ID=$(terraform output -raw test_instance_id)

aws ssm start-session --target $INSTANCE_ID
```

Una vez dentro de la sesión:

```bash
# Test 1: Verificar salida a Internet (a través del NAT)
curl -s --max-time 5 https://checkip.amazonaws.com
# Debe mostrar la IP pública del NAT (EIP del NAT Gateway o IP pública de la instancia NAT)

# Test 2: Verificar acceso a S3 (a través del VPC Endpoint, sin pasar por NAT)
aws s3 ls --region us-east-1 2>&1 | head -5
# Debe listar buckets (si el role tiene permisos) o dar error de permisos (NO timeout)

# Test 3: Verificar que la IP de salida coincide con el NAT
echo "IP de salida: $(curl -s https://checkip.amazonaws.com)"
exit
```

La IP que devuelve `checkip.amazonaws.com` debe coincidir con una de las IPs del output `nat_public_ips` (la correspondiente a la AZ de `private-1`):

```bash
terraform output nat_public_ips
# Debe coincidir con la IP del Test 1
```

### 5.2 Si SSM no conecta

Si `start-session` se queda colgado, verifica:

1. **La instancia está running:** `aws ec2 describe-instance-status --instance-ids $INSTANCE_ID`
2. **El NAT funciona:** SSM necesita salida a Internet para conectarse a los endpoints de Systems Manager. Si el NAT no funciona, SSM tampoco.
3. **El SSM agent arrancó:** Espera 2-3 minutos tras el despliegue para que el agente se registre.

```bash
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=$INSTANCE_ID \
  --query 'InstanceInformationList[].{ID: InstanceId, Ping: PingStatus}' \
  --output table
# PingStatus debe ser "Online"
```

---

## 6. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

Si desplegaste con `-var="use_nat_instance=true"`, incluye la misma variable:

```bash
terraform destroy \
  -var="region=us-east-1" \
  -var="use_nat_instance=true"
```

> **Nota:** No destruyas el bucket S3, ya que es un recurso compartido entre laboratorios (lab02).

---

## 7. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

La Instancia NAT no está disponible en LocalStack (requiere AMIs reales de EC2). Solo se despliega la variante con NAT Gateway.

---

## Buenas prácticas aplicadas

- **NAT Gateway por AZ en producción**: desplegar un NAT Gateway por AZ elimina la dependencia de una única zona para la conectividad de salida. Si una AZ cae, las instancias de las otras AZs mantienen salida a Internet.
- **Instancia NAT solo en desarrollo**: la Instancia NAT es mucho más barata que el NAT Gateway (~$5/mes vs ~$32/mes) pero tiene menor throughput, sin alta disponibilidad y requiere gestión del SO. Usarla solo en entornos no críticos.
- **VPC Gateway Endpoint para S3 y DynamoDB**: el Gateway Endpoint no tiene costo y evita que el tráfico hacia S3 o DynamoDB salga por el NAT Gateway (ahorrando costes de procesamiento). Siempre debe activarse en VPCs con subnets privadas.
- **`count` para despliegue condicional**: usar `count = var.use_nat_gateway ? 1 : 0` permite elegir entre NAT Gateway e Instancia NAT en tiempo de despliegue con una sola variable, sin duplicar código de infraestructura.
- **IP Elástica para el NAT Gateway**: la IP fija del NAT Gateway permite configurar reglas de firewall en los destinos que solo permiten IPs conocidas, sin depender de IPs efímeras.
- **Disable source/dest check en la Instancia NAT**: las instancias EC2 normales descartan paquetes que no van dirigidos a su IP. La Instancia NAT necesita este check deshabilitado para poder reenviar paquetes de otras instancias.

---

## Recursos

- [AWS: NAT Gateway Pricing](https://aws.amazon.com/vpc/pricing/)
- [AWS: VPC Gateway Endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html)
- [AWS: NAT Instances (Legacy)](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html)
- [AWS: Comparison of NAT Gateway vs NAT Instance](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html)
- [Terraform: `aws_nat_gateway`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway)
- [Terraform: `aws_vpc_endpoint`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint)
