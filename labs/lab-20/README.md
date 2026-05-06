# Laboratorio 20 — Hub-and-Spoke con Transit Gateway y RAM

![Terraform on AWS](../../images/lab-banner.svg)


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

- lab-02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado (usado como backend de tfstate)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.10 (necesario para `use_lockfile` en el backend S3)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab-20/
├── README.md                    <- Esta guía
└── aws/
    ├── providers.tf             <- Backend S3 parcial
    ├── variables.tf             <- Variables: region, CIDRs, proyecto, appliance mode
    ├── main.tf                  <- TGW + 4 VPCs (client-a, client-b, inspection, egress) + RAM
    ├── outputs.tf               <- IDs del TGW, attachments, IPs NAT, RAM share
    ├── aws.s3.tfbackend         <- Parámetros del backend (sin bucket)
    └── scripts/
        └── test_init.sh         <- Instalación del SSM Agent
```

## Análisis del código

### 1.1 Arquitectura con inspección y egress centralizados

![Hub-and-Spoke con TGW: 4 VPCs (clients, inspection, egress) + 3 route tables + RAM share](arch/diagrama.svg)

> Fuente editable: [`diagrama.drawio`](diagrama.drawio) — abrir con la extensión
> [Draw.io Integration](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio)
> de VS Code o en [app.diagrams.net](https://app.diagrams.net).

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

> **Aviso de seguridad — `auto_accept_shared_attachments = "enable"`:** con esta opción, **cualquier cuenta que reciba el TGW vía RAM puede crear attachments contra él sin aprobación manual** del equipo propietario del TGW. Es cómodo en un lab y razonable cuando el TGW se comparte solo dentro de una AWS Organization donde confías en todas las cuentas, pero **en escenarios multi-tenant o con cuentas externas conviene dejarlo en `"disable"`** y aceptar cada attachment de forma explícita (consola o `aws ec2 accept-transit-gateway-vpc-attachment`).

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

> **Probar la asimetría sin Appliance Mode (opcional):** la variable `var.enable_appliance_mode` controla el flag. Como no hay un firewall real desplegado en `inspection-vpc` (es solo una VPC vacía con TGW attachment), no se observa el fallo de conexión "drop por estado desconocido"; pero sí puedes ver el cambio en el atributo del attachment con:
>
> ```bash
> terraform apply -var="enable_appliance_mode=false"
>
> # Verificar que el attachment de inspection ahora reporta "disable"
> aws ec2 describe-transit-gateway-vpc-attachments \
>   --filters Name=tag:Name,Values=*inspection* \
>   --query 'TransitGatewayVpcAttachments[].Options.ApplianceModeSupport' \
>   --output text
>
> # Volver al valor por defecto
> terraform apply -var="enable_appliance_mode=true"
> ```
>
> En un escenario real con un firewall stateful (Palo Alto, Fortinet, AWS Network Firewall) en la inspection-vpc, desactivar Appliance Mode provocaría que conexiones TCP largas se cayeran de forma intermitente cuando el hashing del TGW enviara ida y vuelta a AZs distintas — un bug muy difícil de diagnosticar sin entender este detalle.

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

> **Aviso de seguridad — `allow_external_principals = true`:** este flag autoriza a compartir el TGW con cuentas **fuera** de tu AWS Organization. Es necesario cuando uno de los principales es un Account ID externo, como el `var.app_account_id` simulado en este lab. **En entornos reales con Organizations + RAM sharing habilitado**, lo recomendable es ponerlo a `false` para forzar el modelo "solo dentro de la organización" — cualquier intento de compartir hacia fuera se bloquea, lo que limita el blast radius en caso de error humano o credenciales comprometidas.

### 1.7 TGW Flow Logs — Auditar todo el tráfico que atraviesa el hub

```hcl
resource "aws_flow_log" "tgw" {
  transit_gateway_id       = aws_ec2_transit_gateway.main.id
  max_aggregation_interval = 60                # mínimo permitido (1 min)
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.tgw_flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  # traffic_type no aplica a TGW Flow Logs (siempre captura todo el tráfico)
}
```

**¿Por qué TGW Flow Logs y no VPC Flow Logs en la `inspection-vpc`?** En esta topología la `inspection-vpc` está **vacía** (no hay firewall appliance ni instancia EC2). Para flujos de pura transición — origen y destino fuera del CIDR `10.17.0.0/16` — la AWS data plane resuelve el ida-y-vuelta dentro del propio Transit Gateway sin que el paquete llegue a "tocar" una ENI real en inspection. Como los **VPC Flow Logs solo capturan tráfico que atraviesa una ENI**, ese flujo es invisible para los Flow Logs de la VPC. Los **TGW Flow Logs**, en cambio, registran todos los paquetes en el plano del TGW — incluidos los que se descartan por rutas `blackhole` (lo que hace este recurso imprescindible para verificar el aislamiento del Reto 2).

Cada registro de TGW Flow Log incluye campos específicos del plano del Transit Gateway que VPC Flow Logs no tiene:

| Campo | Significado |
|---|---|
| `tgw-id` | ID del Transit Gateway |
| `tgw-attachment-id` | Attachment de **origen** (qué VPC envió el paquete) |
| `tgw-src-vpc-id` / `tgw-dst-vpc-id` | VPC de origen y destino |
| `packet-srcaddr` / `packet-dstaddr` | IPs reales del paquete (antes de cualquier NAT) |
| `srcaddr` / `dstaddr` | IPs vistas en la interfaz del attachment |
| `log-status` | `OK`, `NODATA` o `SKIPDATA` |

Cuando un paquete cae en una ruta `blackhole`, el evento aparece igual en el log con su `tgw-attachment-id` de origen, pero **sin** un attachment de destino. Eso es lo que permite identificar drops por blackhole inequívocamente (ver sección 3.8 y Reto 2 Paso 6).

**Parámetros importantes:**

- **`transit_gateway_id`** (en lugar de `vpc_id`): le dice a AWS que este Flow Log es del nivel TGW, no de una VPC. El recurso `aws_flow_log` también acepta `transit_gateway_attachment_id` para registrar solo un attachment específico — útil si quieres reducir volumen en escenarios con muchas VPCs.
- **`max_aggregation_interval = 60`**: agrega los registros **cada 60 segundos** (mínimo permitido). El default es 600 (10 min). Aquí se baja a 60 para acelerar el feedback durante el lab — los logs aparecen casi en tiempo real en lugar de tener que esperar 10 minutos —, pero esto **multiplica el volumen** ingerido a CloudWatch.
- **No hay `traffic_type`**: TGW Flow Logs siempre capturan todo el tráfico que pasa por el TGW (no admite el filtro `ACCEPT` / `REJECT` / `ALL` que sí tienen los VPC Flow Logs).
- **IAM role compartido**: se reutiliza `aws_iam_role.flow_logs` (mismo service principal `vpc-flow-logs.amazonaws.com` para VPC y TGW Flow Logs).

Para producción, una configuración más razonable sería subir `max_aggregation_interval` a 600 (default) y, si el volumen sigue siendo alto, plantear destinos S3 (más baratos que CloudWatch) con compresión Parquet.

---

## Despliegue

```bash
cd labs/lab-20/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

> **Nota:** La creación del Transit Gateway puede tardar 1-2 minutos.

> **⚠️ Aviso de coste — este es el lab más caro de la serie.** Desglose mensual aproximado en `us-east-1` (asumiendo despliegue base, sin Retos y sin contar el tráfico de datos):
>
> | Componente | Tarifa | Cantidad | Coste/mes |
> |---|---|---:|---:|
> | TGW attachments | $0.05/hora × attachment | 4 | **~$144** |
> | NAT Gateways | $0.045/hora × NAT GW | 2 | **~$65** |
> | Elastic IPs | $0.005/hora × IP pública IPv4 (también si está en uso, desde feb-2024) | 2 | **~$7,20** |
> | CloudWatch Logs (Flow Logs) | ~$0,50/GB ingestado + ~$0,03/GB-mes | variable | **dependiente de tráfico** |
>
> **Total base ≈ 216 USD/mes**, sin contar el tráfico procesado por TGW (~$0,02/GB) ni por NAT GW (~$0,045/GB). Además, `max_aggregation_interval = 60` en los TGW Flow Logs (sección 1.7) eleva el volumen ingerido a CloudWatch — fácilmente varios GB por día con tráfico moderado. Si dejas el lab corriendo, la factura sube rápido. **Ejecuta `terraform destroy` (sección 8) en cuanto termines la práctica** (incluidos los Retos).

Terraform creará ~80 recursos: 4 VPCs, 10 subredes (2 privadas en client-a/b/inspection + 2 públicas + 2 privadas en egress), 6 tablas de rutas con sus asociaciones, ~15 rutas (IGW, NAT, retorno público y privado a clients/inspection, default por VPC), IGW + 2 EIPs + 2 NAT Gateways (uno por AZ), 1 TGW + 4 attachments + 3 TGW Route Tables + 4 asociaciones + 2 rutas estáticas + 5 propagaciones, 3 recursos RAM (share + association + principal), 5 IAM (rol SSM + attach + instance profile + rol Flow Logs + policy Flow Logs) + 1 CloudWatch Log Group + 1 TGW Flow Log, 2 Security Groups y 2 instancias EC2 de test.

```bash
terraform output
# tgw_id              = "tgw-0abc123..."
# client_a_vpc_id     = "vpc-0aaa..."
# client_b_vpc_id     = "vpc-0bbb..."
# inspection_vpc_id   = "vpc-0ccc..."
# egress_vpc_id       = "vpc-0ddd..."
# nat_public_ips              = { "public-1" = "3.xx.xx.xx", "public-2" = "18.xx.xx.xx" }
# appliance_mode              = "enable"
# tgw_flow_log_group          = "/tgw/lab20/flow-logs"
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

> **¿Cómo se conecta el SSM Agent a Internet desde una subred privada sin VPC Endpoints?** Las instancias de test están en `client-a`/`client-b` (subredes privadas, sin IGW, sin VPC Endpoints). El SSM Agent necesita salir a `ssm.us-east-1.amazonaws.com`, `ssmmessages…` y `ec2messages…` para registrarse y atender la sesión. La salida funciona porque la ruta `0.0.0.0/0 → TGW` de cada client encadena `TGW (client-rt) → inspection-vpc → TGW (inspection-rt) → egress-vpc → NAT GW → IGW → Internet`. Es decir, **el propio tráfico de SSM también atraviesa la inspección y el egress centralizado**, igual que un `curl` del Test 2. A diferencia del lab-19, donde se usaron VPC Interface Endpoints porque las VPCs no tenían salida a Internet, aquí la salida existe (centralizada) y los endpoints son innecesarios.

Conectarse a la instancia de test en client-a via SSM Session Manager:

```bash
INSTANCE_A=$(terraform output -raw test_instance_client_a_id)
IP_B=$(terraform output -raw test_instance_client_b_private_ip)
echo "Anota la IP de client-b para usarla dentro de la sesión SSM: $IP_B"

aws ssm start-session --target $INSTANCE_A
```

> **Requisito:** Instalar el [plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) para la AWS CLI. Esperar 2-3 minutos tras el despliegue para que el SSM Agent se registre.

Una vez dentro de la sesión (la sesión SSM **no hereda** las variables de tu shell local, así que sustituye la IP por la que mostró `echo $IP_B` antes):

```bash
# Test 1: Ping a client-b (pasa por inspection via TGW)
ping -c 3 10.19.10.10   # ← reemplaza por el valor de $IP_B impreso arriba
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

### 3.8 Verificar el tráfico que atraviesa el TGW (TGW Flow Logs)

El recurso `aws_flow_log.tgw` (sección 1.7) registra **todos los paquetes que pasan por el Transit Gateway**, incluidos los de tránsito puro entre VPCs vacías de hosts. Cada registro identifica el `tgw-attachment-id` de origen, las IPs originales del paquete (`packet-srcaddr` / `packet-dstaddr`) y, cuando aplique, la `tgw-route-table-id` consultada.

**Paso 1:** Generar tráfico desde client-a (ping a client-b y curl a Internet, como en 3.6).

**Paso 2:** Esperar 1-2 minutos para que los flow logs se publiquen en CloudWatch (`max_aggregation_interval = 60`).

**Paso 3:** Visualizar el tráfico inter-VPC entre client-a (`10.16.10.10`) y client-b (`10.19.10.10`) usando **CloudWatch Logs Insights**.

El formato default de los TGW Flow Logs tiene 30+ campos space-separated cuya posición exacta varía según la versión del provider y la cuenta — por eso un parser por posiciones (`awk '{ print $13, $14 ... }'`) es frágil. Logs Insights nos permite extraer los campos por **patrón** (regex con grupos nombrados), independientemente de su orden en la línea, y muestra los resultados como tabla nativa en la consola.

**Cómo abrir la consola:** AWS Console → CloudWatch → Logs Insights → seleccionar log group `/tgw/lab20/flow-logs` → pegar la consulta de abajo → *Run query*.

```
fields @timestamp, @message
| parse @message /(?<srcAttach>tgw-attach-\w+)/
| parse @message /(?<pktSrc>(?:\d{1,3}\.){3}\d{1,3})\s+(?<pktDst>(?:\d{1,3}\.){3}\d{1,3})/
| parse @message /\s(?<protocol>1|6|17)\s+(?<packets>\d+)\s+(?<bytes>\d+)\s+\d{10}\s+\d{10}\s+(?<logStatus>OK|NODATA|SKIPDATA)/
| filter (pktSrc = "10.16.10.10" and pktDst = "10.19.10.10")
      or (pktSrc = "10.19.10.10" and pktDst = "10.16.10.10")
| display @timestamp, pktSrc, pktDst, protocol, packets, bytes, srcAttach, logStatus
| sort @timestamp desc
| limit 50
```

Salida esperada (cuando **no** hay blackhole — flujo bidireccional client-a ↔ client-b):

| @timestamp | pktSrc | pktDst | protocol | packets | bytes | srcAttach | logStatus |
|---|---|---|---|---|---|---|---|
| 2026-05-03 10:42:01 | 10.16.10.10 | 10.19.10.10 | 1 | 3 | 252 | tgw-attach-aaaa1111 | OK |
| 2026-05-03 10:42:01 | 10.19.10.10 | 10.16.10.10 | 1 | 3 | 252 | tgw-attach-bbbb2222 | OK |

Aparecen **dos sentidos**: la ida (`10.16.10.10 → 10.19.10.10`, attachment de client-a como origen) y la vuelta (`10.19.10.10 → 10.16.10.10`, attachment de client-b como origen). La presencia de ambas filas confirma que el TGW enruta el tráfico a través de la cadena `client-rt → inspection-rt → client-rt`.

> **Notas sobre los campos extraídos por regex:**
>
> - `srcAttach`: primer ID `tgw-attach-...` que aparece en la línea — corresponde al `tgw-attachment-id` del attachment **de origen** (la VPC que envió el paquete).
> - `pktSrc` / `pktDst`: las dos primeras IPs `X.X.X.X` consecutivas en la línea — son el `packet-srcaddr` / `packet-dstaddr` del paquete original.
> - `protocol`: `1` = ICMP, `6` = TCP, `17` = UDP. El regex limita a esos valores para evitar falsos positivos con otros números del log.
> - `logStatus`: `OK` (registro normal), `NODATA` (sin paquetes en el intervalo) o `SKIPDATA` (registros perdidos por capacidad).

**Paso 4:** Visualizar el tráfico a Internet desde client-a (recorre `client-rt → inspection → egress → IGW`):

```
fields @timestamp, @message
| parse @message /(?<srcAttach>tgw-attach-\w+)/
| parse @message /(?<pktSrc>(?:\d{1,3}\.){3}\d{1,3})\s+(?<pktDst>(?:\d{1,3}\.){3}\d{1,3})/
| parse @message /\s(?<protocol>1|6|17)\s+(?<packets>\d+)\s+(?<bytes>\d+)\s+\d{10}\s+\d{10}\s+(?<logStatus>OK|NODATA|SKIPDATA)/
| filter pktSrc = "10.16.10.10" and pktDst != "10.19.10.10"
| display @timestamp, pktSrc, pktDst, protocol, packets, bytes, srcAttach, logStatus
| sort @timestamp desc
| limit 50
```

Verás filas con `pktDst` apuntando a IPs públicas (resolvers DNS, `checkip.amazonaws.com`, etc.). El `srcAttach` sigue siendo el de client-a, confirmando que la cadena `client-a → inspection → egress` está activa.

> **Ejecutar las mismas consultas desde la CLI** (útil para automatizar):
>
> ```bash
> LOG_GROUP=$(terraform output -raw tgw_flow_log_group)
>
> QUERY_ID=$(aws logs start-query \
>   --log-group-name "$LOG_GROUP" \
>   --start-time $(( $(date +%s) - 1800 )) \
>   --end-time   $(date +%s) \
>   --query-string 'fields @timestamp, @message
>     | parse @message /(?<srcAttach>tgw-attach-\w+)/
>     | parse @message /(?<pktSrc>(?:\d{1,3}\.){3}\d{1,3})\s+(?<pktDst>(?:\d{1,3}\.){3}\d{1,3})/
>     | filter (pktSrc = "10.16.10.10" and pktDst = "10.19.10.10")
>          or (pktSrc = "10.19.10.10" and pktDst = "10.16.10.10")
>     | display @timestamp, pktSrc, pktDst, srcAttach
>     | sort @timestamp desc
>     | limit 20' \
>   --query 'queryId' --output text)
>
> # Logs Insights tarda 5-15 s en ejecutar. Espera y luego pide los resultados:
> sleep 10
> aws logs get-query-results --query-id "$QUERY_ID" --output json | jq '.results'
> ```

---

## Retos

### Reto 1 — Añadir una tercera client-vpc

**Situación**: El equipo de desarrollo necesita una nueva VPC (`client-c`) para un proyecto piloto. Debe integrarse en la topología existente con las mismas restricciones: todo el tráfico pasa por inspection, y la salida a Internet se centraliza en egress.

**Tu objetivo**:

1. Crear una nueva VPC `client-c` con CIDR `10.20.0.0/16` y subredes privadas en 2 AZs
2. Crear un TGW attachment para client-c
3. Asociar el attachment a la tabla `client-rt` existente (no crear una nueva tabla — la ruta `0.0.0.0/0 → inspection` ya aplica)
4. Propagar la ruta de client-c en `inspection-rt` y `egress-rt` para que el tráfico de retorno llegue
5. Añadir una ruta por defecto `0.0.0.0/0 → TGW` en la tabla de rutas de la VPC
6. Añadir las rutas de retorno en las tablas pública y privadas de egress
7. Crear un Security Group para client-c (mismo patrón que `test_client_a`/`test_client_b`) **y una instancia de test** con `private_ip = 10.20.10.10` — sin esto la verificación con `ping` no tiene a quién responder
8. Verificar que client-a puede hacer ping a client-c y que client-c puede acceder a Internet
9. Verificar con `terraform plan` que no se modifican los recursos existentes (solo adiciones)

**Pistas**:
- Solo necesitas **añadir** recursos, no modificar ninguno existente (el SG de client-a no se toca: como los SGs son stateful, la respuesta del ping vuelve automáticamente)
- El attachment de client-c se asocia a `client-rt` con `aws_ec2_transit_gateway_route_table_association`
- La ruta `0.0.0.0/0 → inspection` ya existe en `client-rt` y aplica automáticamente a todos los attachments asociados a esa tabla
- Necesitas propagar client-c en `inspection-rt` y `egress-rt` para que inspection y egress sepan devolver el tráfico a `10.20.0.0/16`
- Las rutas de retorno en egress son necesarias tanto en la tabla pública (para el NAT GW) como en cada tabla privada
- La instancia de test debe fijar `private_ip = cidrhost(aws_subnet.client_c["private-1"].cidr_block, 10)` para que coincida con el `10.20.10.10` que se pinga desde client-a, igual que se hace con `test_client_a` y `test_client_b`

### Reto 2 — Aislamiento entre clientes

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

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Añadir una tercera client-vpc</strong></summary>

### Solución al Reto 1 — Añadir una tercera client-vpc

#### Paso 1: Nueva variable

En `variables.tf`, añadir:

```hcl
variable "client_c_cidr" {
  type        = string
  description = "CIDR block de la VPC client-c"
  default     = "10.20.0.0/16"
}
```

#### Paso 2: VPC, subredes y tabla de rutas

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

#### Paso 3: TGW attachment y asociacion a client-rt

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

#### Paso 4: Propagar rutas de retorno en inspection-rt y egress-rt

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

#### Paso 5: Rutas de retorno en egress

Añadir `client_c` al mapa de `egress_public_to_clients` y `egress_private_to_clients`, o crear rutas adicionales:

```hcl
resource "aws_route" "egress_public_to_client_c" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.client_c_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route" "egress_private_to_client_c" {
  # Iteramos sobre las subredes privadas (mismo conjunto de claves que las
  # tablas de rutas privadas), de forma análoga al patrón usado en el resto
  # del lab para las rutas de retorno.
  for_each = aws_subnet.egress_private

  route_table_id         = aws_route_table.egress_private[each.key].id
  destination_cidr_block = var.client_c_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}
```

#### Paso 6: Security Group e instancia de test en client-c

> **Por qué este paso es imprescindible:** sin un host que escuche en `10.20.10.10`, el `ping` de la verificación se pierde aunque toda la red esté bien configurada — el plumbing TGW + rutas + propagaciones llega correctamente a la subred privada de client-c, pero allí no hay nadie que responda. Hay que crear (a) el Security Group de client-c con las reglas ICMP equivalentes a las de `test_client_a` / `test_client_b` y (b) la instancia EC2 de test fijando `private_ip = 10.20.10.10`.

```hcl
resource "aws_security_group" "test_client_c" {
  name        = "test-client-c-${var.project_name}"
  description = "Permite ICMP desde otras VPCs y trafico saliente"
  vpc_id      = aws_vpc.client_c.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.client_a_cidr, var.client_b_cidr, var.inspection_cidr, var.egress_cidr]
    description = "ICMP desde otras VPCs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el tra                                                                                                                                                                  fico saliente"
  }

  tags = merge(local.common_tags, {
    Name = "test-client-c-sg-${var.project_name}"
  })
}

resource "aws_instance" "test_client_c" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.client_c["private-1"].id
  vpc_security_group_ids = [aws_security_group.test_client_c.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  private_ip             = cidrhost(aws_subnet.client_c["private-1"].cidr_block, 10)

  user_data = file("${path.module}/scripts/test_init.sh")

  tags = merge(local.common_tags, {
    Name = "test-client-c-${var.project_name}"
  })

  depends_on = [
    aws_route.client_c_default,
    aws_ec2_transit_gateway_route_table_association.client_c,
    aws_ec2_transit_gateway_route_table_propagation.client_c_to_inspection,
    aws_ec2_transit_gateway_route_table_propagation.client_c_to_egress,
    aws_route.egress_private_to_client_c,
    aws_nat_gateway.egress,
  ]
}
```

Y los outputs correspondientes en `outputs.tf` — el ID se usa para abrir la sesión SSM (Paso 7) y la IP privada para validar que `private_ip` se asignó como esperabas (`10.20.10.10`) y para reusarla en pings desde otras instancias:

```hcl
output "test_instance_client_c_id" {
  description = "ID de la instancia de test en client-c"
  value       = aws_instance.test_client_c.id
}

output "test_instance_client_c_private_ip" {
  description = "IP privada de la instancia de test en client-c"
  value       = aws_instance.test_client_c.private_ip
}
```

> **Nota sobre el SG de client-a:** los Security Groups de AWS son **stateful** — la respuesta ICMP de `test-client-c` vuelve automáticamente al `test-client-a` que originó la conexión, aunque el SG de client-a no incluya `var.client_c_cidr` en su lista de ingress. Por eso este paso solo crea el SG de client-c y no toca los existentes. Si quisieras que client-c **inicie** ping hacia client-a (dirección inversa), entonces sí tendrías que añadir `var.client_c_cidr` al ingress ICMP de `test_client_a` (y de `test_client_b` si aplica).

#### Paso 7: Verificar

```bash
terraform plan
# Plan: ~17 to add, 0 to change, 0 to destroy
# (VPC, subredes, tabla de rutas, asociaciones, attachment, propagaciones,
#  rutas egress, SG client-c, instancia test, 2 outputs)

terraform apply
```

Antes de abrir la sesión SSM, anota la IP privada que Terraform asignó a la instancia de test en client-c (debe ser `10.20.10.10`):

```bash
IP_C=$(terraform output -raw test_instance_client_c_private_ip)
echo "IP de test-client-c: $IP_C"   # debería imprimir 10.20.10.10
```

Verificar que client-c tiene conectividad. La validación tiene **dos partes** — la primera prueba la transitividad por inspection (igual que el ping client-a ↔ client-b) y la segunda prueba la cadena completa hasta Internet:

```bash
# (1) Desde client-a, hacer ping a client-c (recorre client-rt → inspection → client-c)
aws ssm start-session --target $(terraform output -raw test_instance_client_a_id)
ping -c 3 10.20.10.10   # ← reemplaza por el valor de $IP_C si lo cambiaste
# Debe responder. Si sale "Request timeout", verifica:
#   - que la instancia test-client-c está running y registrada en SSM
#   - que el SG test-client-c admite ICMP desde var.client_a_cidr
#   - que los SGs de los endpoints de la cadena no bloquean (en este lab no hay)
exit
```

```bash
# (2) Desde client-c, hacer curl a Internet (recorre client-c → TGW → inspection → TGW → egress → NAT → IGW)
INSTANCE_C=$(terraform output -raw test_instance_client_c_id)
aws ssm start-session --target $INSTANCE_C
```

```bash
# Dentro de la sesión SSM en client-c
curl -s --max-time 5 https://checkip.amazonaws.com
# Debe mostrar una de las IPs públicas de los NAT Gateways de egress (la
# misma que vio client-a en la sección 3.6 — se confirma que el egress
# centralizado también atiende al nuevo client).
exit
```

</details>

<details>
<summary><strong>Solución al Reto 2 — Aislamiento entre clientes</strong></summary>

### Solución al Reto 2 — Aislamiento entre clientes

Antes de tocar el código conviene visualizar lo que va a cambiar. Hay dos rutas (ida y vuelta) y dos escenarios (inter-VPC vs Internet). El objetivo es **bloquear el inter-VPC** sin romper la salida a Internet:

```
Antes — inspection-rt tiene propagadas client-a, client-b
========================================================

  ┌── client-a ──► TGW (client-rt: 0/0 → inspection)
  │                    ──► inspection ──► TGW (inspection-rt: 10.19/16 → client-b)  ──► client-b   [inter-VPC permitido]
  │
  └── client-a ──► TGW (client-rt: 0/0 → inspection)
                       ──► inspection ──► TGW (inspection-rt: 0/0 → egress) ──► egress ──► Internet


Después — inspection-rt SIN propagaciones, CON blackholes /16
=============================================================

  ┌── client-a ──► TGW (client-rt: 0/0 → inspection)
  │                    ──► inspection ──► TGW (inspection-rt: 10.19/16 BLACKHOLE)   ──► descartado  [inter-VPC bloqueado]
  │
  └── client-a ──► TGW (client-rt: 0/0 → inspection)
                       ──► inspection ──► TGW (inspection-rt: 0/0 → egress) ──► egress ──► Internet  (sigue funcionando)
                       ◄────────────────────── retorno ────── TGW (egress-rt: 10.16/16 → client-a) ──► client-a
```

Dos puntos clave para entender por qué basta con el blackhole:

1. **Las rutas blackhole `/16` ganan a `0.0.0.0/0 → egress`**: TGW evalúa por especificidad, así que el tráfico inter-VPC se descarta en `inspection-rt` antes de llegar a la ruta por defecto. El tráfico a Internet (cuyo destino *no* coincide con ningún `/16` blackhole) sí cae en `0.0.0.0/0 → egress`.
2. **`egress-rt` mantiene las propagaciones**: el retorno de Internet (egress → client) usa `egress-rt`, no `inspection-rt`. El asimetría es intencional — solo *ida* a Internet pasa por inspection; el *retorno* va directo por egress.

#### Paso 1: Eliminar propagaciones de clients en inspection-rt

Eliminar las propagaciones de **todos** los clients en `main.tf` (incluyendo client-c si completaste el Reto 1):

```hcl
# ELIMINAR:
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_a_to_inspection" { ... }
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_b_to_inspection" { ... }
# resource "aws_ec2_transit_gateway_route_table_propagation" "client_c_to_inspection" { ... }  # si existe
```

> **⚠️ Si completaste el Reto 1 — actualiza `depends_on` de `test_client_c`:** la instancia `aws_instance.test_client_c` que añadiste en el Reto 1 incluye en su `depends_on` la referencia `aws_ec2_transit_gateway_route_table_propagation.client_c_to_inspection`. Al eliminar ese recurso aquí, Terraform fallará con `Reference to undeclared resource` durante el `plan`. Hay que **comentar (o eliminar) esa línea del `depends_on`** de `aws_instance.test_client_c`:
>
> ```hcl
> resource "aws_instance" "test_client_c" {
>   # ...
>   depends_on = [
>     aws_route.client_c_default,
>     aws_ec2_transit_gateway_route_table_association.client_c,
>     # aws_ec2_transit_gateway_route_table_propagation.client_c_to_inspection,  # ← comentar/eliminar (eliminado en Reto 2)
>     aws_ec2_transit_gateway_route_table_propagation.client_c_to_egress,
>     aws_route.egress_private_to_client_c,
>     aws_nat_gateway.egress,
>   ]
> }
> ```
>
> El resto de dependencias se mantienen: `egress_private_to_client_c` sigue siendo necesario para la salida a Internet desde client-c.

#### Paso 2: Añadir rutas blackhole en inspection-rt

Sin las propagaciones, el tráfico inter-VPC caería en `0.0.0.0/0 → egress`, y como egress-rt tiene las rutas propagadas de los clients, el paquete llegaría igualmente al destino — saltándose la inspección en el camino de vuelta. Las rutas blackhole descartan explícitamente el tráfico hacia los CIDRs de los clients.

Declarar en `variables.tf` en una variable de tipo lista para mantener los blackholes de forma escalable:

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

#### Paso 3: Verificar el plan

```bash
terraform plan
# Plan: N to add, 0 to change, N to destroy
# (N propagaciones eliminadas, N blackholes añadidos — donde N es el número de clients)

terraform apply
```

#### Paso 4: Verificar aislamiento

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

#### Paso 5: Verificar el contenido de `inspection-rt`

**Objetivo:** confirmar a nivel del TGW que el cambio se aplicó correctamente — es decir, que la tabla `inspection-rt` tiene exactamente lo que esperamos:

- **1 ruta `static/active`**: `0.0.0.0/0 → egress` (la que permite la salida a Internet, no se ha tocado).
- **N rutas `blackhole`**: una por cada CIDR de client (`10.16/16`, `10.19/16`, y `10.20/16` si completaste el Reto 1). Estas son las que provocan el aislamiento inter-VPC.
- **0 rutas `propagated`**: las propagaciones que tenía antes (`client_a/b/c_to_inspection`) deben haber desaparecido.

Si alguna de estas tres condiciones falla, el `apply` no quedó coherente y los pasos 4 y 6 darán resultados engañosos.

**Localiza el ID de la tabla:**

```bash
TGW_ID=$(terraform output -raw tgw_id)

INSP_RT=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID Name=tag:Name,Values=*inspection* \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' \
  --output text)
echo "inspection-rt: $INSP_RT"
```

**(a) Rutas en estado `active`** — solo debería aparecer la ruta por defecto a egress:

```bash
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $INSP_RT \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type, State: State}' \
  --output table
```

Salida esperada:

```
-------------------------------------------------
|         SearchTransitGatewayRoutes            |
+-----------+----------+-----------+
|   CIDR    |   State  |   Type    |
+-----------+----------+-----------+
| 0.0.0.0/0 | active   | static    |
+-----------+----------+-----------+
```

> Si ves además rutas `propagated` con CIDRs `10.16/16`, `10.19/16` o `10.20/16`, es que **no eliminaste las propagaciones del Paso 1** o el `apply` no se ha completado. Sin eliminarlas, el blackhole no aplica (las propagaciones tienen la misma especificidad `/16` y ganarían en función del orden, dejando bypass abierto). Vuelve al Paso 1 y revisa.

**(b) Rutas en estado `blackhole`** — debe haber una entrada por cada CIDR de client en `var.client_cidrs`:

```bash
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $INSP_RT \
  --filters Name=state,Values=blackhole \
  --query 'Routes[].{CIDR: DestinationCidrBlock, Type: Type, State: State}' \
  --output table
```

Salida esperada (con Reto 1 completado, 3 entradas; sin Reto 1, solo 2):

```
+----------------+-----------+----------+
|     CIDR       |   State   |   Type   |
+----------------+-----------+----------+
| 10.16.0.0/16   | blackhole | static   |
| 10.19.0.0/16   | blackhole | static   |
| 10.20.0.0/16   | blackhole | static   |
+----------------+-----------+----------+
```

> Si la tabla sale vacía o con menos entradas de las esperadas, revisa que el `for_each = toset(var.client_cidrs)` del Paso 2 se haya aplicado y que `var.client_cidrs` contenga todos los CIDRs (incluido `10.20.0.0/16` si hiciste el Reto 1).

**(c) — Opcional — comprobar que ya no hay propagaciones de client en `inspection-rt`** (debe salir vacío):

```bash
aws ec2 get-transit-gateway-route-table-propagations \
  --transit-gateway-route-table-id $INSP_RT \
  --query 'TransitGatewayRouteTablePropagations[?State==`enabled`].{Attachment: TransitGatewayAttachmentId, ResourceType: ResourceType, State: State}' \
  --output table
```

Si aún aparece algún attachment de tipo `vpc` (los de `client-a/b/c`), es que el Paso 1 se quedó a medias y el `apply` no destruyó el recurso `aws_ec2_transit_gateway_route_table_propagation.client_*_to_inspection`.

#### Paso 6: Verificar el blackhole en TGW Flow Logs

Los TGW Flow Logs (sección 1.7) registran el plano del Transit Gateway, no el de las VPC, así que **sí capturan los paquetes descartados por rutas `blackhole`** — al contrario que los VPC Flow Logs, que solo ven tráfico que atraviesa ENI reales.

**Paso 1:** Genera tráfico con el ping fallido del Paso 4 (si ya lo lanzaste y el log se ingirió, salta este paso):

```bash
aws ssm start-session --target $(terraform output -raw test_instance_client_a_id)
ping -c 5 -W 2 10.19.10.10   # falla por el blackhole, pero genera registros en TGW Flow Logs
exit
```

Espera 1-2 minutos a la ingestión (`max_aggregation_interval = 60`).

**Paso 2:** Visualizar el flujo blackholed con **CloudWatch Logs Insights** (mismo enfoque que en la sección 3.8 — extracción por regex con grupos nombrados, sin depender de posiciones).

Abre AWS Console → CloudWatch → Logs Insights → log group `/tgw/lab20/flow-logs` → pega esta consulta y *Run query*:

```
fields @timestamp, @message
| parse @message /(?<srcAttach>tgw-attach-\w+)/
| parse @message /(?<pktSrc>(?:\d{1,3}\.){3}\d{1,3})\s+(?<pktDst>(?:\d{1,3}\.){3}\d{1,3})/
| parse @message /\s(?<protocol>1|6|17)\s+(?<packets>\d+)\s+(?<bytes>\d+)\s+\d{10}\s+\d{10}\s+(?<logStatus>OK|NODATA|SKIPDATA)/
| filter (pktSrc = "10.16.10.10" and pktDst = "10.19.10.10")
      or (pktSrc = "10.19.10.10" and pktDst = "10.16.10.10")
| display @timestamp, pktSrc, pktDst, protocol, packets, bytes, srcAttach, logStatus
| sort @timestamp desc
| limit 50
```

Salida esperada **tras aplicar Reto 2** — solo aparecen los pings de **ida** desde client-a y **no hay filas de vuelta** (porque el paquete se descartó antes de llegar a client-b):

| @timestamp | pktSrc | pktDst | protocol | packets | bytes | srcAttach | logStatus |
|---|---|---|---|---|---|---|---|
| 2026-05-03 11:05:13 | 10.16.10.10 | 10.19.10.10 | 1 | 5 | 420 | tgw-attach-aaaa1111 | OK |

Compáralo con la salida equivalente de la sección 3.8 (cuando todavía **no** estaba el blackhole): allí también aparecía la fila de retorno `10.19.10.10 → 10.16.10.10` con el `srcAttach` de client-b. Aquí solo hay ida → es la huella del aislamiento.

> **Cómo identificar drop por blackhole en el log raw (opcional):** además de la ausencia de la fila de retorno, **el registro de ida** tiene un patrón distintivo si miras la línea raw: el `srcAttach` (attachment de client-a) está presente, pero los campos relacionados con el attachment de destino — `tgw-dst-vpc-account-id`, `tgw-dst-vpc-id`, `tgw-dst-az-id`, `tgw-pair-attachment-id` — aparecen como `-` (vacíos), porque el paquete nunca alcanzó un attachment de destino: lo descartó la regla `10.19.0.0/16 → blackhole` antes de que el TGW pudiera elegir uno.
>
> Para verlo, ejecuta una consulta cruda (sin parse) que muestre el `@message` completo:
>
> ```
> fields @timestamp, @message
> | filter @message like /10\.16\.10\.10/ and @message like /10\.19\.10\.10/
> | sort @timestamp desc
> | limit 5
> ```

**Paso 3 (opcional) — comparar con un flujo permitido:** ejecuta la misma consulta pero filtrando el tráfico **a Internet** desde client-a, que sigue funcionando (cae en `0.0.0.0/0 → egress`, no en el blackhole):

```
fields @timestamp, @message
| parse @message /(?<srcAttach>tgw-attach-\w+)/
| parse @message /(?<pktSrc>(?:\d{1,3}\.){3}\d{1,3})\s+(?<pktDst>(?:\d{1,3}\.){3}\d{1,3})/
| filter pktSrc = "10.16.10.10" and pktDst != "10.19.10.10"
| display @timestamp, pktSrc, pktDst, srcAttach
| sort @timestamp desc
| limit 20
```

Aquí sí aparecen registros con `pktDst` apuntando a IPs públicas — confirmación de que el blackhole afecta solo al tráfico inter-VPC, no a la salida a Internet.

> **Conclusión técnica del Reto 2:** los blackhole drops son **invisibles para los VPC Flow Logs** (la inspection-vpc en este lab no tiene host de terminación) pero **completamente visibles para los TGW Flow Logs**. Esa es la razón por la que el lab habilita TGW Flow Logs desde el inicio — sin ellos, este Reto solo se podría verificar indirectamente con la combinación ping-fallido + estado de la tabla de rutas (Pasos 4 y 5).
>
> **Lección aplicable a producción:** en una topología hub-and-spoke real, lo habitual es desplegar un firewall stateful (AWS Network Firewall, Palo Alto VM-Series, Fortinet, etc.) en la inspection-vpc; en ese caso, los VPC Flow Logs de inspection **sí** capturan ACCEPT/REJECT (el paquete termina en la ENI del firewall), y además puedes inspeccionar a Capa 7. Pero los TGW Flow Logs siguen siendo útiles porque ven el plano del hub completo — incluyendo blackholes y rutas que los firewalls no observan.

**¿Por qué funciona el aislamiento?**

| Trafico | Flujo | Resultado |
|---|---|---|
| client-a → client-b | client-a → TGW (client-rt: `0.0.0.0/0 → inspection`) → inspection → TGW (inspection-rt: `10.19.0.0/16 → blackhole`) → **descartado** | Bloqueado |
| client-a → Internet | client-a → TGW (client-rt: `0.0.0.0/0 → inspection`) → inspection → TGW (inspection-rt: `0.0.0.0/0 → egress`) → egress → NAT → IGW → Internet | Funciona |
| Internet → client-a | Internet → IGW → NAT → egress → TGW (egress-rt: `10.16.0.0/16 → client-a`) → client-a | Funciona |

Las rutas blackhole (`/16`) tienen mayor especificidad que la ruta por defecto (`/0`), por lo que el TGW las evalúa primero. El tráfico inter-VPC se descarta en inspection-rt antes de llegar a la ruta `0.0.0.0/0 → egress`.

> **Nota:** En producción, AWS Network Firewall en la inspection-vpc sería el encargado de aplicar políticas de acceso entre VPCs de forma granular, permitiendo algunos flujos y bloqueando otros según reglas de negocio.

</details>

---

## Limpieza

```bash
terraform destroy
```

> **Nota:** La destrucción del Transit Gateway puede tardar 1-2 minutos. El laboratorio no crea ningún bucket S3 propio: no destruyas el bucket de tfstate del lab-02 (`terraform-state-labs-<ACCOUNT_ID>`), ya que es un recurso compartido entre laboratorios.

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
