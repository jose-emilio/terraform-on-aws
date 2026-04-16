# Laboratorio 20 — Hub-and-Spoke con Transit Gateway y RAM

[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Centralizar la interconectividad de múltiples VPCs mediante un **Transit Gateway (TGW)** central con **inspección obligatoria** de todo el tráfico, **salida a Internet centralizada** a través de una egress-vpc con NAT Gateway altamente disponible (uno por AZ), y compartición del TGW entre cuentas con **AWS Resource Access Manager (RAM)**.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Transit Gateway (TGW)** | Hub de conectividad regional que conecta VPCs y redes on-premise mediante un único punto central. Escala a miles de VPCs sin necesidad de peerings individuales |
| **TGW Attachment** | Asociación entre el TGW y una VPC (o VPN/Direct Connect). Cada VPC se conecta al TGW a través de un attachment en una o más subredes |
| **TGW Route Table** | Tabla de rutas interna del TGW que determina cómo se reenvían paquetes entre attachments. Múltiples tablas permiten segmentar tráfico |
| **Hub-and-Spoke** | Topología de red donde un nodo central (hub/TGW) conecta múltiples nodos periféricos (spokes/VPCs). Simplifica la gestión: N VPCs requieren N attachments en vez de N×(N-1)/2 peerings |
| **VPC Peering vs TGW** | Peering es punto a punto, no transitivo, sin coste base pero inmanejable a escala. TGW tiene coste base (~$36/mes) pero escala linealmente y soporta enrutamiento transitivo |
| **AWS RAM** | Servicio que permite compartir recursos de AWS entre cuentas sin duplicarlos. Usado aquí para compartir el TGW con una cuenta de aplicación simulada |
| **Appliance Mode** | Opción del TGW attachment que fuerza simetría de tráfico: los paquetes de ida y vuelta de un flujo pasan por la misma AZ. Esencial para firewalls stateful de terceros |
| **Inspección centralizada** | Patrón donde todo el tráfico inter-VPC y a Internet pasa por una VPC de inspección con firewall/IDS antes de llegar al destino |
| **Egress centralizado** | Patrón donde una única VPC concentra la salida a Internet (IGW + NAT Gateway por AZ), eliminando la necesidad de NAT Gateways en cada VPC |

## Comparativa: Peering vs Transit Gateway

| Aspecto | VPC Peering | Transit Gateway |
|---|---|---|
| Topología | Punto a punto | Hub-and-spoke |
| Transitividad | No (A-B y B-C no implica A-C) | Sí (enrutamiento transitivo) |
| Conexiones para 5 VPCs | 10 peerings | 5 attachments |
| Conexiones para 20 VPCs | 190 peerings | 20 attachments |
| Coste base | $0 | ~$36/mes por attachment |
| Coste por GB | $0.01 (cross-AZ) | $0.02 por GB procesado |
| Inspección centralizada | No nativo | Sí (con VPC de inspección) |
| Límite | 125 peerings por VPC | 5.000 attachments por TGW |

> **Regla práctica:** Usa VPC Peering para 2-3 VPCs con conectividad simple. Usa Transit Gateway a partir de 4+ VPCs, cuando necesites transitividad, inspección centralizada o conectividad híbrida (VPN/Direct Connect).

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab20/
├── README.md                    <- Esta guía
└── aws/
    ├── providers.tf             <- Backend S3 parcial
    ├── variables.tf             <- Variables: region, CIDRs, proyecto, appliance mode
    ├── main.tf                  <- TGW + 4 VPCs (client-a, client-b, inspection, egress) + RAM
    ├── outputs.tf               <- IDs del TGW, attachments, IPs NAT, RAM share
    ├── aws.s3.tfbackend         <- Parámetros del backend (sin bucket)
    └── scripts/
        └── test_init.sh         <- Instalacion del SSM Agent
```

## 1. Análisis del código

### 1.1 Arquitectura con inspección y egress centralizados

```
                         ┌─────────────────┐
                         │ Transit Gateway │
                         │   (Hub/TGW)     │
                         └──┬──┬──┬──┬─────┘
                            │  │  │  │
              ┌─────────────┘  │  │  └───────────────┐
              │                │  │                  │
              v                v  v                  v
      ┌──────────────┐ ┌────────────────┐   ┌───────────────┐
      │ VPC client-a │ │ VPC inspection │   │  VPC egress   │
      │ 10.16.0.0/16 │ │ 10.17.0.0/16   │   │ 10.18.0.0/16  │
      └──────────────┘ │ (Appliance     │   │ IGW + NAT×2AZ │
      ┌──────────────┐ │  Mode)         │   └───────┬───────┘
      │ VPC client-b │ └────────────────┘           │
      │ 10.19.0.0/16 │                           Internet
      └──────────────┘
```

Cuatro VPCs conectadas al TGW. El tráfico se segmenta mediante **tres tablas de rutas del TGW** que fuerzan todo el tráfico a pasar por inspection antes de llegar a su destino o a Internet.

**Flujo de tráfico resumido:**

```
client-a/b ── TGW (client-rt: 0.0.0.0/0 → inspection)
                              │
                    inspection-vpc (firewall)
                              │
               TGW (inspection-rt: 0.0.0.0/0 → egress)
                              │
                    egress-vpc ── NAT GW (×2 AZ) ── IGW ── Internet
```

### 1.2 Transit Gateway — Tablas de rutas personalizadas

```hcl
resource "aws_ec2_transit_gateway" "main" {
  description                     = "TGW central - Hub-and-Spoke lab20"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "enable"
}
```

A diferencia de una configuración simple donde se usa la tabla por defecto, aquí se deshabilitan `default_route_table_association` y `default_route_table_propagation`. Esto obliga a crear **tres tablas de rutas independientes** con asociaciones y propagaciones explícitas:

| Tabla | Attachments asociados | Ruta por defecto | Rutas propagadas |
|---|---|---|---|
| **client-rt** | client-a, client-b | `0.0.0.0/0 → inspection` | Ninguna |
| **inspection-rt** | inspection | `0.0.0.0/0 → egress` | client-a, client-b |
| **egress-rt** | egress | Ninguna | client-a, client-b, inspection |

Con esta configuración, los clients **no pueden comunicarse directamente entre sí** — todo el tráfico pasa obligatoriamente por inspection. La VPC de inspección decide qué tráfico permitir, bloquear o registrar.

**¿Por qué no propagar rutas de clients en client-rt?**

Si propagáramos los CIDRs de client-a y client-b en client-rt, el tráfico inter-VPC iría directo de un client a otro sin pasar por inspection. Al tener **solo** la ruta `0.0.0.0/0 → inspection`, todo el tráfico — incluyendo el inter-VPC — se fuerza a pasar por la VPC de inspección.

### 1.3 Flujo de tráfico detallado

**Tráfico entre client-a y client-b:**

1. client-a envía paquete a `10.19.x.x` → ruta VPC `0.0.0.0/0 → TGW`
2. TGW consulta **client-rt**: no hay ruta específica para `10.19.0.0/16`, aplica `0.0.0.0/0 → inspection` → reenvía a inspection-vpc
3. inspection-vpc (firewall) inspecciona el paquete y lo reenvía → ruta VPC `0.0.0.0/0 → TGW`
4. TGW consulta **inspection-rt**: encuentra `10.19.0.0/16 → client-b` (ruta propagada) → reenvía a client-b
5. La respuesta de client-b sigue el camino inverso: client-b → TGW (client-rt) → inspection → TGW (inspection-rt) → client-a

**Tráfico a Internet desde client-a:**

1. client-a envía paquete a `8.8.8.8` → ruta VPC `0.0.0.0/0 → TGW`
2. TGW consulta **client-rt**: `0.0.0.0/0 → inspection` → reenvía a inspection-vpc
3. inspection-vpc inspecciona y reenvía → ruta VPC `0.0.0.0/0 → TGW`
4. TGW consulta **inspection-rt**: `0.0.0.0/0 → egress` → reenvía a egress-vpc
5. egress-vpc: subred privada `0.0.0.0/0 → NAT GW (de la misma AZ)` → subred pública `0.0.0.0/0 → IGW` → Internet
6. Respuesta vuelve: IGW → NAT GW → ruta de retorno en tabla pública `10.16.0.0/16 → TGW` → **egress-rt**: `10.16.0.0/16 → client-a` (propagada), pero el tráfico debe volver por inspection → **egress-rt** reenvía a inspection → **inspection-rt**: `10.16.0.0/16 → client-a` (propagada) → client-a

### 1.4 Appliance Mode — Simetría de tráfico para firewalls

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
  vpc_id                 = aws_vpc.inspection.id
  subnet_ids             = [for k, s in aws_subnet.inspection : s.id]
  appliance_mode_support = var.enable_appliance_mode ? "enable" : "disable"
}
```

**¿Qué problema resuelve Appliance Mode?**

Sin Appliance Mode, el TGW distribuye el tráfico entre AZs usando un algoritmo de hashing basado en la tupla de 5 elementos (IP origen, IP destino, puerto origen, puerto destino, protocolo). Esto puede causar que los paquetes de ida de un flujo TCP pasen por la AZ-a del firewall y los de vuelta por la AZ-b.

Un firewall stateful (como Palo Alto, Fortinet o AWS Network Firewall) mantiene una **tabla de estados** de conexiones. Si solo ve los paquetes de ida pero no los de vuelta (porque van por otra AZ), descarta el tráfico de retorno como "conexión desconocida".

Con `appliance_mode_support = "enable"`, el TGW garantiza que todos los paquetes de un mismo flujo pasen por la **misma AZ**, manteniendo la simetría requerida por los firewalls stateful.

### 1.5 Egress centralizado — NAT Gateway por AZ

```hcl
resource "aws_eip" "nat_egress" {
  for_each = aws_subnet.egress_public
  domain   = "vpc"
}

resource "aws_nat_gateway" "egress" {
  for_each      = aws_subnet.egress_public
  allocation_id = aws_eip.nat_egress[each.key].id
  subnet_id     = each.value.id
}
```

La egress-vpc concentra toda la salida a Internet del hub. Se despliega **un NAT Gateway por AZ** para alta disponibilidad:

- Si cae una AZ, las subredes privadas de la otra AZ mantienen salida a Internet
- Sin tráfico cross-AZ: cada subred privada sale por el NAT de su misma AZ
- Cada NAT Gateway tiene su propia EIP (2 IPs públicas de salida)

**Rutas de retorno:**

Las tablas de rutas **pública** y **privada** de egress necesitan rutas de retorno hacia las otras VPCs (`10.16.0.0/16 → TGW`, `10.17.0.0/16 → TGW`, `10.19.0.0/16 → TGW`). Sin estas rutas, el NAT Gateway traduce la respuesta de Internet pero no sabe cómo devolverla a la VPC de origen — la única ruta disponible sería `0.0.0.0/0 → IGW`, que la enviaría de vuelta a Internet.

### 1.6 AWS RAM — Compartir el TGW entre cuentas

```hcl
resource "aws_ram_resource_share" "tgw" {
  name                      = "tgw-share-${var.project_name}"
  allow_external_principals = true
}

resource "aws_ram_resource_association" "tgw" {
  resource_share_arn = aws_ram_resource_share.tgw.arn
  resource_arn       = aws_ec2_transit_gateway.main.arn
}

resource "aws_ram_principal_association" "app_account" {
  resource_share_arn = aws_ram_resource_share.tgw.arn
  principal          = var.app_account_id
}
```

RAM permite compartir el TGW con otras cuentas de AWS **sin recrearlo**. En un entorno real, el equipo de networking gestionaría el TGW en una cuenta central de red y lo compartiría con las cuentas de aplicación via RAM. Las cuentas receptoras pueden crear attachments contra el TGW compartido.

En este lab, `var.app_account_id` simula una cuenta de aplicación (por defecto `123456789012`). En producción, sería el ID real de la cuenta que necesita conectividad.

> **Nota:** Para que la asociación RAM se complete, la cuenta receptora debe aceptar la invitación (a menos que ambas cuentas pertenezcan a la misma AWS Organization con sharing habilitado, en cuyo caso se acepta automáticamente).

---

## 2. Despliegue

```bash
cd labs/lab20/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

> **Nota:** La creación del Transit Gateway puede tardar 1-2 minutos.

Terraform creará ~55 recursos: 4 VPCs, subredes públicas y privadas en egress, IGW, 2 NAT Gateways (uno por AZ), TGW, 4 attachments, 3 tablas de rutas TGW con asociaciones y propagaciones, rutas en las VPCs, RAM resource share e instancias de test con SSM.

```bash
terraform output
# tgw_id              = "tgw-0abc123..."
# client_a_vpc_id     = "vpc-0aaa..."
# client_b_vpc_id     = "vpc-0bbb..."
# inspection_vpc_id   = "vpc-0ccc..."
# egress_vpc_id       = "vpc-0ddd..."
# nat_public_ips              = { "public-1" = "3.xx.xx.xx", "public-2" = "18.xx.xx.xx" }
# appliance_mode              = "enable"
# inspection_flow_log_group   = "/vpc/lab20/inspection-flow-logs"
# ram_resource_share          = "arn:aws:ram:us-east-1:123456789012:resource-share/xxx"
```

---

## Verificación final

### 3.1 Transit Gateway y attachments

Verificar que el TGW está en estado `available` y que los 4 attachments están conectados:

```bash
aws ec2 describe-transit-gateways \
  --filters Name=tag:Project,Values=lab20 \
  --query 'TransitGateways[].{ID: TransitGatewayId, State: State}' \
  --output table

aws ec2 describe-transit-gateway-vpc-attachments \
  --filters Name=tag:Project,Values=lab20 \
  --query 'TransitGatewayVpcAttachments[].{Name: Tags[?Key==`Name`].Value|[0], ID: TransitGatewayAttachmentId, State: State}' \
  --output table
```

Deberías ver 4 attachments en estado `available`: client-a, client-b, inspection y egress.

### 3.2 Tablas de rutas del TGW

Listar las 3 tablas de rutas personalizadas y verificar sus rutas:

```bash
TGW_ID=$(terraform output -raw tgw_id)

# Listar las 3 tablas de rutas
aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID \
  --query 'TransitGatewayRouteTables[].{Name: Tags[?Key==`Name`].Value|[0], ID: TransitGatewayRouteTableId}' \
  --output table
```

Verificar las rutas de cada tabla:

```bash
# client-rt: solo debe tener 0.0.0.0/0 → inspection (ruta estática)
CLIENT_RT=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID Name=tag:Name,Values=*client* \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' \
  --output text)

aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $CLIENT_RT \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type}' \
  --output table
```

```bash
# inspection-rt: debe tener 0.0.0.0/0 → egress (estática) + CIDRs de clients (propagadas)
INSP_RT=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID Name=tag:Name,Values=*inspection* \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' \
  --output text)

aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $INSP_RT \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type}' \
  --output table
```

```bash
# egress-rt: debe tener CIDRs de clients + inspection (propagadas)
EGRESS_RT=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID Name=tag:Name,Values=*egress* \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' \
  --output text)

aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $EGRESS_RT \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type}' \
  --output table
```

Resumen esperado:

| Tabla | Rutas esperadas |
|---|---|
| client-rt | `0.0.0.0/0` (static) |
| inspection-rt | `0.0.0.0/0` (static), `10.16.0.0/16` (propagated), `10.19.0.0/16` (propagated) |
| egress-rt | `10.16.0.0/16` (propagated), `10.17.0.0/16` (propagated), `10.19.0.0/16` (propagated) |

### 3.3 Appliance Mode

Verificar que el attachment de inspection tiene Appliance Mode habilitado:

```bash
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters Name=tag:Name,Values=*inspection* \
  --query 'TransitGatewayVpcAttachments[].{ID: TransitGatewayAttachmentId, ApplianceMode: Options.ApplianceModeSupport}' \
  --output table
```

Debe mostrar `ApplianceModeSupport = enable`.

### 3.4 NAT Gateways en egress (alta disponibilidad)

Verificar que hay un NAT Gateway por AZ en la egress-vpc:

```bash
aws ec2 describe-nat-gateways \
  --filter Name=tag:Project,Values=lab20 \
  --query 'NatGateways[].{Name: Tags[?Key==`Name`].Value|[0], AZ: SubnetId, State: State, PublicIP: NatGatewayAddresses[0].PublicIp}' \
  --output table
```

Deberías ver 2 NAT Gateways en estado `available`, cada uno en una subred pública de AZ diferente.

### 3.5 RAM Resource Share

Verificar que el TGW esta compartido via RAM:

```bash
aws ram get-resource-shares \
  --resource-owner SELF \
  --tag-filters tagKey=Project,tagValues=lab20 \
  --query 'resourceShares[].{Name: name, Status: status, ARN: resourceShareArn}' \
  --output table
```

### 3.6 Verificar conectividad inter-VPC (instancias de test)

Conectarse a la instancia de test en client-a via SSM Session Manager:

```bash
INSTANCE_A=$(terraform output -raw test_instance_client_a_id)
IP_B=$(terraform output -raw test_instance_client_b_private_ip)

aws ssm start-session --target $INSTANCE_A
```

> **Requisito:** Instalar el [plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) para la AWS CLI. Esperar 2-3 minutos tras el despliegue para que el SSM Agent se registre.

Una vez dentro de la sesión:

```bash
# Test 1: Ping a client-b (pasa por inspection via TGW)
ping -c 3 10.19.10.10
# Debe responder si las rutas, SGs y tablas TGW están correctos

# Test 2: Verificar salida a Internet (pasa por inspection → egress → NAT → IGW)
curl -s --max-time 5 https://checkip.amazonaws.com
# Debe mostrar una de las IPs públicas de los NAT Gateways de egress

exit
```

Verificar que la IP de salida coincide con uno de los NAT Gateways:

```bash
terraform output nat_public_ips
# La IP del curl debe coincidir con la EIP de la AZ donde esta la subred privada de egress
```

### 3.7 Si SSM no conecta

Si `start-session` se queda colgado, verificar:

```bash
INSTANCE_A=$(terraform output -raw test_instance_client_a_id)

# 1. La instancia esta running
aws ec2 describe-instance-status --instance-ids $INSTANCE_A \
  --query 'InstanceStatuses[].{State: InstanceState.Name}' --output text

# 2. El SSM Agent se registro (puede tardar 2-3 min)
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=$INSTANCE_A \
  --query 'InstanceInformationList[].{ID: InstanceId, Ping: PingStatus}' \
  --output table
# PingStatus debe ser "Online"
```

Si PingStatus no es "Online", el user_data no pudo instalar el SSM Agent. Esto ocurre si la ruta a Internet no está completa. Verificar que las rutas por defecto en las VPCs, las tablas del TGW y las rutas de retorno en egress están todas configuradas.

### 3.8 Verificar que el tráfico pasa por inspection (Flow Logs)

La inspection-vpc tiene habilitados VPC Flow Logs que capturan **todo** el tráfico (ACCEPT y REJECT). Esto permite demostrar que el tráfico entre clients y hacia Internet realmente atraviesa la VPC de inspección.

**Paso 1:** Generar tráfico desde client-a (ping a client-b y curl a Internet, como en 3.6).

**Paso 2:** Esperar 5-10 minutos para que los flow logs se publiquen en CloudWatch.

**Paso 3:** Buscar tráfico ICMP entre client-a (`10.16.10.10`) y client-b (`10.19.10.10`) en los flow logs de inspection:

```bash
LOG_GROUP=$(terraform output -raw inspection_flow_log_group)

# Buscar paquetes de client-a en los flow logs de inspection
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "10.16.10.10" \
  --max-items 5 \
  --query 'events[].message' \
  --output table
```

Si aparecen registros con la IP de client-a (`10.16.10.10`) en los flow logs de **inspection**, confirma que el tráfico inter-VPC pasa por la VPC de inspección. Si los clients se comunicaran directamente (sin pasar por inspection), estos registros no existirían.

**Paso 4:** Buscar tráfico de client-b para confirmar que ambas direcciones pasan por inspection:

```bash
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "10.19.10.10" \
  --max-items 5 \
  --query 'events[].message' \
  --output table
```

> **Formato de cada línea:** `version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status`

---

## 4. Reto: Añadir una tercera client-vpc

**Situación**: El equipo de desarrollo necesita una nueva VPC (`client-c`) para un proyecto piloto. Debe integrarse en la topología existente con las mismas restricciones: todo el tráfico pasa por inspection, y la salida a Internet se centraliza en egress.

**Tu objetivo**:

1. Crear una nueva VPC `client-c` con CIDR `10.20.0.0/16` y subredes privadas en 2 AZs
2. Crear un TGW attachment para client-c
3. Asociar el attachment a la tabla `client-rt` existente (no crear una nueva tabla — la ruta `0.0.0.0/0 → inspection` ya aplica)
4. Propagar la ruta de client-c en `inspection-rt` y `egress-rt` para que el tráfico de retorno llegue
5. Añadir una ruta por defecto `0.0.0.0/0 → TGW` en la tabla de rutas de la VPC
6. Añadir las rutas de retorno en las tablas pública y privadas de egress
7. Verificar que client-c puede hacer ping a client-a y acceder a Internet
8. Verificar con `terraform plan` que no se modifican los recursos existentes (solo adiciones)

**Pistas**:
- Solo necesitas **añadir** recursos, no modificar ninguno existente
- El attachment de client-c se asocia a `client-rt` con `aws_ec2_transit_gateway_route_table_association`
- La ruta `0.0.0.0/0 → inspection` ya existe en `client-rt` y aplica automáticamente a todos los attachments asociados a esa tabla
- Necesitas propagar client-c en `inspection-rt` y `egress-rt` para que inspection y egress sepan devolver el tráfico a `10.20.0.0/16`
- Las rutas de retorno en egress son necesarias tanto en la tabla pública (para el NAT GW) como en cada tabla privada

La solución está en la [sección 5](#5-solucion-del-reto).

---

## 5. Solución del Reto

### Paso 1: Nueva variable

En `variables.tf`, añadir:

```hcl
variable "client_c_cidr" {
  type        = string
  description = "CIDR block de la VPC client-c"
  default     = "10.20.0.0/16"
}
```

### Paso 2: VPC, subredes y tabla de rutas

Añadir en `main.tf` la VPC con el mismo patrón que client-a y client-b:

```hcl
resource "aws_vpc" "client_c" {
  cidr_block           = var.client_c_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-client-c-${var.project_name}"
  })
}

resource "aws_subnet" "client_c" {
  for_each = { for idx, az in local.azs : "private-${idx + 1}" => { az = az, index = 10 + idx } }

  vpc_id            = aws_vpc.client_c.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(aws_vpc.client_c.cidr_block, 8, each.value.index)

  tags = merge(local.common_tags, {
    Name = "client-c-${each.key}-${var.project_name}"
    Tier = "private"
  })
}

resource "aws_route_table" "client_c" {
  vpc_id = aws_vpc.client_c.id

  tags = merge(local.common_tags, {
    Name = "client-c-rt-${var.project_name}"
  })
}

resource "aws_route_table_association" "client_c" {
  for_each = aws_subnet.client_c

  subnet_id      = each.value.id
  route_table_id = aws_route_table.client_c.id
}

resource "aws_route" "client_c_default" {
  route_table_id         = aws_route_table.client_c.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.client_c]
}
```

### Paso 3: TGW attachment y asociacion a client-rt

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "client_c" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.client_c.id
  subnet_ids         = [for k, s in aws_subnet.client_c : s.id]

  tags = merge(local.common_tags, {
    Name = "tgw-att-client-c-${var.project_name}"
  })
}

# Asociar a la misma tabla que client-a y client-b.
# La ruta 0.0.0.0/0 → inspection ya existe y aplica automáticamente.
resource "aws_ec2_transit_gateway_route_table_association" "client_c" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_c.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.client.id
}
```

### Paso 4: Propagar rutas de retorno en inspection-rt y egress-rt

```hcl
resource "aws_ec2_transit_gateway_route_table_propagation" "client_c_to_inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_c.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "client_c_to_egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.client_c.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}
```

### Paso 5: Rutas de retorno en egress

Añadir `client_c` al mapa de `egress_public_to_clients` y `egress_private_to_clients`, o crear rutas adicionales:

```hcl
resource "aws_route" "egress_public_to_client_c" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.client_c_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route" "egress_private_to_client_c" {
  for_each = aws_route_table.egress_private

  route_table_id         = each.value.id
  destination_cidr_block = var.client_c_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}
```

### Paso 6: Verificar

```bash
terraform plan
# Plan: ~12 to add, 0 to change, 0 to destroy
# (VPC, subredes, tabla de rutas, asociaciones, attachment, propagaciones, rutas egress)

terraform apply
```

Verificar que client-c tiene conectividad:

```bash
# Desde client-a, hacer ping a client-c
aws ssm start-session --target $(terraform output -raw test_instance_client_a_id)
ping -c 3 10.20.10.10
```

---

## 6. Reto 2: Aislamiento entre clients

**Situación**: El equipo de cumplimiento requiere que las VPCs de clientes sean **completamente independientes** entre sí. Cada client debe poder acceder a Internet (via inspection → egress), pero **no** debe poder ver ni alcanzar el tráfico de otros clients. Un ping de client-a a client-b debe fallar.

Actualmente, client-a puede hacer ping a client-b porque inspection-rt tiene las rutas propagadas de ambos clients. Cuando client-a envía tráfico a `10.19.x.x`, pasa por inspection, y inspection-rt sabe devolver el paquete a client-b.

**Tu objetivo**:

1. Eliminar las propagaciones de client-a y client-b en `inspection-rt` (quitar `client_a_to_inspection` y `client_b_to_inspection`)
2. Mantener la ruta por defecto `0.0.0.0/0 → egress` en `inspection-rt` para que la salida a Internet siga funcionando
3. Verificar que el ping de client-a a client-b **falla** (timeout)
4. Verificar que el curl a Internet desde client-a **sigue funcionando**
5. Comprobar en los Flow Logs de inspection que el tráfico ICMP entre clients aparece como REJECT

**Pistas**:
- Sin las rutas propagadas de clients en `inspection-rt`, cuando inspection reenvía el paquete al TGW, inspection-rt no tiene ruta a `10.19.0.0/16`. Solo tiene `0.0.0.0/0 → egress`, así que el paquete va a egress, que tampoco sabe llegar a client-b directamente → el paquete se descarta
- Pero si eliminas las propagaciones, el tráfico de retorno de Internet (egress → inspection → client) también se pierde. Necesitas una solución alternativa
- La clave es que `egress-rt` **sí** tiene las propagaciones de clients (para las rutas de retorno del NAT). El tráfico de retorno de Internet llega a egress y egress-rt sabe reenviarlo directamente a los clients
- Por tanto, puedes cambiar el flujo de retorno: en vez de `egress → inspection → client`, el retorno va `egress → client` directamente (egress-rt tiene las rutas propagadas)
- Solo el tráfico de **ida** pasa por inspection; el de retorno de Internet vuelve directo por egress-rt

La solución está en la [sección 7](#7-solucion-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Eliminar propagaciones de clients en inspection-rt

Eliminar las propagaciones de **todos** los clients en `main.tf` (incluyendo client-c si completaste el Reto 1):

```hcl
# ELIMINAR:
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_a_to_inspection" { ... }
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_b_to_inspection" { ... }
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_c_to_inspection" { ... }  # si existe
```

### Paso 2: Añadir rutas blackhole en inspection-rt

Sin las propagaciones, el tráfico inter-VPC caería en `0.0.0.0/0 → egress`, y como egress-rt tiene las rutas propagadas de los clients, el paquete llegaría igualmente al destino — saltándose la inspección en el camino de vuelta. Las rutas blackhole descartan explícitamente el tráfico hacia los CIDRs de los clients.

Usar una variable de tipo lista para mantener los blackholes de forma escalable:

```hcl
variable "client_cidrs" {
  type        = list(string)
  description = "CIDRs de todas las VPCs de clientes (para blackhole en inspection-rt)"
  default     = ["10.16.0.0/16", "10.19.0.0/16"]
  # Si completaste el Reto 1, añadir: ["10.16.0.0/16", "10.19.0.0/16", "10.20.0.0/16"]
}
```

```hcl
resource "aws_ec2_transit_gateway_route" "blackhole_clients" {
  for_each = toset(var.client_cidrs)

  destination_cidr_block         = each.value
  blackhole                      = true
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}
```

Las rutas blackhole tienen mayor prioridad que la ruta por defecto `0.0.0.0/0 → egress` porque son más específicas (`/16` vs `/0`). El tráfico hacia cualquier CIDR de client se descarta antes de llegar a la ruta por defecto. Al usar `for_each` sobre una lista, añadir un nuevo client al aislamiento es tan simple como agregar su CIDR a `var.client_cidrs`.

### Paso 3: Verificar el plan

```bash
terraform plan
# Plan: N to add, 0 to change, N to destroy
# (N propagaciones eliminadas, N blackholes añadidos — donde N es el número de clients)

terraform apply
```

### Paso 4: Verificar aislamiento

```bash
INSTANCE_A=$(terraform output -raw test_instance_client_a_id)

aws ssm start-session --target $INSTANCE_A
```

```bash
# El ping a client-b debe fallar (timeout)
ping -c 3 -W 2 10.19.10.10
# 100% packet loss

# La salida a Internet debe seguir funcionando
curl -s --max-time 5 https://checkip.amazonaws.com
# Debe mostrar la IP del NAT Gateway

exit
```

### Paso 5: Verificar en inspection-rt

```bash
TGW_ID=$(terraform output -raw tgw_id)

INSP_RT=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID Name=tag:Name,Values=*inspection* \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' \
  --output text)

# Rutas activas (ruta por defecto)
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $INSP_RT \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type, State: State}' \
  --output table

# Rutas blackhole (estado "blackhole", no "active")
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $INSP_RT \
  --filters Name=state,Values=blackhole \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type, State: State}' \
  --output table
```

Debe mostrar `0.0.0.0/0` (static/active) y las rutas blackhole de cada client (`10.16.0.0/16`, `10.19.0.0/16`, y `10.20.0.0/16` si completaste el Reto 1). Las rutas propagadas ya no están.

### Paso 6: Verificar en Flow Logs

Despues de intentar el ping fallido, buscar en los flow logs de inspection:

```bash
LOG_GROUP=$(terraform output -raw inspection_flow_log_group)

aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "REJECT" \
  --max-items 5 \
  --query 'events[].message' \
  --output table
```

**¿Por qué funciona el aislamiento?**

| Trafico | Flujo | Resultado |
|---|---|---|
| client-a → client-b | client-a → TGW (client-rt: `0.0.0.0/0 → inspection`) → inspection → TGW (inspection-rt: `10.19.0.0/16 → blackhole`) → **descartado** | Bloqueado |
| client-a → Internet | client-a → TGW (client-rt: `0.0.0.0/0 → inspection`) → inspection → TGW (inspection-rt: `0.0.0.0/0 → egress`) → egress → NAT → IGW → Internet | Funciona |
| Internet → client-a | Internet → IGW → NAT → egress → TGW (egress-rt: `10.16.0.0/16 → client-a`) → client-a | Funciona |

Las rutas blackhole (`/16`) tienen mayor especificidad que la ruta por defecto (`/0`), por lo que el TGW las evalúa primero. El tráfico inter-VPC se descarta en inspection-rt antes de llegar a la ruta `0.0.0.0/0 → egress`.

> **Nota:** En producción, AWS Network Firewall en la inspection-vpc sería el encargado de aplicar políticas de acceso entre VPCs de forma granular, permitiendo algunos flujos y bloqueando otros según reglas de negocio.

---

## 8. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** La destrucción del Transit Gateway puede tardar 1-2 minutos. No destruyas el bucket S3 (lab02).

---

## Buenas prácticas aplicadas

- **Una tabla de rutas por segmento de red**: separar las tablas de rutas del TGW por tipo de VPC (spoke, egress, inspection) permite aplicar políticas de enrutamiento diferenciadas sin mezclar tráfico de distintos contextos de seguridad.
- **Appliance Mode en el attachment de inspección**: habilitar `appliance_mode_support = "enable"` garantiza que los flujos TCP en ambas direcciones llegan al mismo appliance, evitando el fallo de conexión cuando el appliance tiene estado (stateful).
- **NAT Gateway por AZ en la egress-VPC**: desplegar un NAT Gateway en cada AZ de la egress-VPC elimina la dependencia de una única AZ para la salida a Internet de todas las VPCs spoke.
- **RAM para compartir el TGW sin peering de cuentas**: compartir el Transit Gateway con otras cuentas via AWS RAM es más escalable que el VPC Peering individual y no requiere coordinación de CIDR entre cuentas.
- **Rutas de retorno explícitas en las tablas de rutas**: el tráfico de respuesta debe tener una ruta explícita de vuelta a las VPCs spoke. Olvidar estas rutas es el error más común en arquitecturas TGW.
- **`default_route_table_association = "disable"`**: deshabilitar la asociación automática a la tabla de rutas por defecto fuerza a declarar explícitamente cada asociación, evitando rutas involuntarias.

---

## Recursos

- [AWS: Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)
- [AWS: Transit Gateway Route Tables](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-route-tables.html)
- [AWS: Appliance Mode](https://docs.aws.amazon.com/vpc/latest/tgw/how-transit-gateways-work.html)
- [AWS: Centralized Egress with Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)
- [AWS: Centralized Inspection Architecture](https://docs.aws.amazon.com/prescriptive-guidance/latest/inline-traffic-inspection-third-party-appliances/)
- [AWS: Resource Access Manager](https://docs.aws.amazon.com/ram/latest/userguide/what-is.html)
- [Terraform: `aws_ec2_transit_gateway`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway)
- [Terraform: `aws_ec2_transit_gateway_route_table`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table)
- [Terraform: `aws_ec2_transit_gateway_route`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route)
- [Terraform: `aws_ram_resource_share`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ram_resource_share)
