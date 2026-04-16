# Sección 5 — Interconectividad de VPCs

> [← Sección anterior](./04_sg_nacl.md) | [Siguiente →](./06_conectividad_hibrida.md)

---

## 5.1 Conectando Mundos: ¿Por qué Interconectar VPCs?

A medida que una organización crece en AWS, una sola VPC ya no es suficiente. Por seguridad, cumplimiento o separación de responsabilidades, los equipos crean VPCs separadas para producción, desarrollo, seguridad, redes compartidas, etc.

Pero estos entornos necesitan comunicarse: la VPC de aplicación necesita acceder a la VPC de bases de datos, el equipo de seguridad necesita inspeccionar tráfico de todas las cuentas, los servicios compartidos (DNS, monitoreo) necesitan ser accesibles desde todas partes.

Dos soluciones principales: **VPC Peering** para conexiones simples 1:1 y **Transit Gateway** para redes corporativas complejas.

---

## 5.2 VPC Peering: Conexión Directa 1:1

VPC Peering crea un túnel privado entre dos VPCs usando la red interna de AWS. El tráfico nunca pasa por Internet, mantiene baja latencia y no hay coste de procesamiento de datos (solo transferencia estándar entre regiones).

```hcl
# VPC de Aplicación
resource "aws_vpc" "app" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "vpc-app" }
}

# VPC de Base de Datos
resource "aws_vpc" "db" {
  cidr_block = "10.1.0.0/16"
  tags       = { Name = "vpc-db" }
}

# Solicitar el peering (auto_accept = true solo funciona en la misma cuenta y región)
resource "aws_vpc_peering_connection" "app_to_db" {
  vpc_id      = aws_vpc.app.id
  peer_vpc_id = aws_vpc.db.id
  auto_accept = true

  tags = { Name = "peer-app-db" }
}

# Ruta en VPC App → hacia DB (en la tabla Custom, nunca en la Main RT)
resource "aws_route" "app_to_db" {
  route_table_id            = aws_route_table.app_private.id
  destination_cidr_block    = "10.1.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}

# Ruta en VPC DB → hacia App (bidireccional obligatorio)
resource "aws_route" "db_to_app" {
  route_table_id            = aws_route_table.db_private.id
  destination_cidr_block    = "10.0.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}
```

**Requisitos críticos del peering:**
- CIDRs no solapados entre las VPCs (se planifica en la fase 1.2)
- Las rutas deben añadirse en **ambas** VPCs — la conexión en sí no crea rutas automáticamente
- `auto_accept = true` solo funciona cuando las dos VPCs están en la misma cuenta y región; para cross-account o cross-region requiere aceptación explícita

---

## 5.3 La Gran Limitación: El Enrutamiento No Transitivo

> "VPC Peering no es transitivo: si A↔B y B↔C, eso NO significa que A pueda hablar con C."

Esta es la limitación más importante del VPC Peering. Cuando el número de VPCs crece, la complejidad escala cuadráticamente:

| VPCs | Peerings necesarios (full mesh) |
|------|--------------------------------|
| 3 | 3 |
| 5 | 10 |
| 10 | 45 |
| 20 | **190** |

Con 20 VPCs necesitarías gestionar 190 conexiones de peering, 380 cambios de route tables, y coordinar SGs entre todas las combinaciones. Inmanejable.

Limitaciones adicionales:
- No hay "edge-to-edge routing" (no puedes salir a Internet de otra VPC a través del peering)
- No comparte IGW/NAT/VPN entre VPCs
- Máximo 125 peerings activos por VPC
- No soporta multicast

La solución para estos escenarios es **Transit Gateway**.

---

## 5.4 Transit Gateway: El Router Cloud Hub-and-Spoke

Transit Gateway (TGW) es el router regional de AWS que actúa como hub central. Todas las redes se conectan como spokes:

```
VPC-App ──────┐
VPC-DB  ───────┤
VPC-Dev ───────┤──→ Transit Gateway ←── VPN On-Premise
VPC-Sec ───────┤                    ←── Direct Connect
Shared  ───────┘
```

Con TGW, N VPCs = N attachments (lineal, no cuadrático). Y lo mejor: el TGW soporta **enrutamiento transitivo** — App puede llegar a DB a través del TGW aunque no haya un peering directo entre ellas.

```hcl
resource "aws_ec2_transit_gateway" "main" {
  description                     = "TGW central de la organización"
  amazon_side_asn                 = 64512
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = { Name = "tgw-central" }
}
```

---

## 5.5 TGW Attachments: Enchufar VPCs al Router Central

Un **TGW Attachment** es el enlace lógico entre tu VPC y el Transit Gateway. El TGW crea ENIs invisibles en las subredes especificadas para mover el tráfico:

```hcl
# Conectar la VPC de App al TGW
resource "aws_ec2_transit_gateway_vpc_attachment" "app" {
  subnet_ids         = [
    aws_subnet.app_private_a.id,
    aws_subnet.app_private_b.id     # Al menos 1 subred por AZ
  ]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.app.id

  tags = { Name = "tgw-att-app" }
}
```

---

## 5.6 El Checklist Crítico: El "Doble Salto" de Rutas

> Este es el error número 1 con Transit Gateway: configurar los attachments y asumir que todo funciona.

**Configurar el TGW y los attachments NO es suficiente.** El TGW sabe qué VPCs están conectadas, pero las VPCs NO saben que deben enviar tráfico al TGW. Debes añadir rutas en cada VPC:

```hcl
# VPC App necesita saber que para llegar a 10.1.0.0/16 (DB) debe ir por el TGW
resource "aws_route" "app_to_db" {
  route_table_id         = aws_route_table.app_private.id
  destination_cidr_block = "10.1.0.0/16"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}

# VPC DB necesita saber que para llegar a 10.0.0.0/16 (App) debe ir por el TGW
resource "aws_route" "db_to_app" {
  route_table_id         = aws_route_table.db_private.id
  destination_cidr_block = "10.0.0.0/16"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}
```

Checklist obligatorio:
- ✓ TGW creado
- ✓ Attachment VPC configurado (con subredes en cada AZ)
- ✓ Route Tables del TGW con las propagaciones correctas
- ✓ `aws_route` en **cada** VPC apuntando al TGW para los prefijos remotos

---

## 5.7 Segmentación con TGW Route Tables

El TGW tiene sus propias tablas de rutas internas que permiten aislar entornos dentro del mismo router:

```
Dev  ──→ TGW RT "dev"   ──→ Solo ve Shared Services
Prod ──→ TGW RT "prod"  ──→ Ve Shared Services, NO ve Dev
Sec  ──→ TGW RT "sec"   ──→ Ve todo (para inspección)
```

Con `default_route_table_association = "disable"` y tablas de rutas TGW custom, implementas Zero Trust Network Access dentro de tu propia red corporativa.

---

## 5.8 Gobernanza Multi-Cuenta: AWS RAM

En organizaciones con múltiples cuentas AWS (usando AWS Organizations), el TGW puede crearse en la cuenta de Networking y compartirse con el resto:

```hcl
# En la cuenta de Networking
resource "aws_ram_resource_share" "tgw_share" {
  name                      = "tgw-shared"
  allow_external_principals = false   # Solo cuentas de la organización

  tags = { Environment = "network" }
}

# Asociar el TGW al share
resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.main.arn
  resource_share_arn = aws_ram_resource_share.tgw_share.arn
}

# Invitar a la cuenta de App
resource "aws_ram_principal_association" "app_account" {
  principal          = var.app_account_id
  resource_share_arn = aws_ram_resource_share.tgw_share.arn
}

# En la cuenta de App: aceptar la invitación
resource "aws_ram_resource_share_accepter" "accept" {
  share_arn = aws_ram_resource_share.tgw_share.arn
  provider  = aws.app_account
}
```

Con RAM, la cuenta de App puede crear TGW Attachments al TGW central sin necesidad de crear su propio Transit Gateway. Una sola infraestructura de routing para toda la organización.

---

## 5.9 Appliance Mode: Inspección de Tráfico Centralizada

Cuando hay un firewall virtual (Palo Alto, Fortinet) inspeccionando tráfico Este-Oeste, el TGW debe garantizar que la ida y la vuelta del mismo flujo pasen por la misma AZ del appliance:

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  subnet_ids         = [aws_subnet.inspection_a.id, aws_subnet.inspection_b.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.inspection.id

  # CRÍTICO: mantiene simetría de flujo para firewalls stateful
  appliance_mode_support = "enable"

  tags = { Name = "tgw-att-inspection" }
}
```

Sin `appliance_mode_support = "enable"`, el TGW puede enviar la ida por AZ-a y la vuelta por AZ-b. El firewall ve solo medio flujo, pierde estado y descarta paquetes. La red funciona pero el firewall "cree" que hay intrusiones.

---

## 5.10 TGW Inter-Región: Redes Globales

Para conectar TGWs en diferentes regiones (arquitectura multi-región para DR o latencia):

```hcl
# En us-east-1 — solicitar el peering
resource "aws_ec2_transit_gateway_peering_attachment" "us_to_eu" {
  peer_account_id         = data.aws_caller_identity.current.account_id
  peer_region             = "eu-west-1"
  peer_transit_gateway_id = var.tgw_eu_id
  transit_gateway_id      = aws_ec2_transit_gateway.us.id

  tags = { Name = "tgw-peer-us-eu" }
}
```

El tráfico viaja por el backbone privado de AWS entre regiones — no sale a Internet. La latencia es predecible y el tráfico es privado. Nota: las rutas son estáticas (no hay propagación BGP entre regiones).

---

## 5.11 FinOps: Estrategia Híbrida de Costes

| Servicio | Coste | Cuando usarlo |
|---------|-------|---------------|
| VPC Peering | Sin coste de procesamiento (solo transferencia) | 2-5 VPCs con tráfico alto entre ellas |
| Transit Gateway | $0.05/hora/attachment + $0.02/GB procesado | 6+ VPCs, routing centralizado, VPN compartida |

**Regla de oro:**
- Si dos VPCs intercambian >100 GB/día de forma constante → **Peering directo** (ahorra el coste por GB del TGW)
- Si necesitas routing centralizado, inspección de seguridad o conectar muchas VPCs → **Transit Gateway**
- Ambos pueden coexistir: Peering para flujos de datos masivos (ETL, backups), TGW para el resto

Con 10 attachments en TGW: ~$360/mes base + coste por GB. Con Peering entre las VPCs de alto volumen: sin coste de procesamiento. La combinación puede ahorrar cientos de dólares al mes en organizaciones grandes.

---

## 5.12 Resumen: Conectividad Multi-VPC

```
Pocas VPCs (2-5), mismo dueño:   VPC Peering
    → Simple, sin coste de procesamiento, no transitivo

Muchas VPCs, multi-cuenta:       Transit Gateway
    → Hub-and-Spoke, transitivo, Route Tables para segmentación

VPCs con alto tráfico constante: Peering + TGW combinados
    → Peering para flujos masivos, TGW para orquestación
```

| Característica | VPC Peering | Transit Gateway |
|----------------|------------|-----------------|
| Transitividad | No (full mesh) | Sí (Hub-and-Spoke) |
| Escalabilidad | O(n²) peerings | O(n) attachments |
| Multi-cuenta | Sí (con aceptación) | Sí (con RAM) |
| Inter-región | Sí | Sí (peering TGW) |
| Inspección centralizada | No | Sí (Appliance Mode) |
| Coste | Solo transferencia | $0.05/h + $0.02/GB |

> **Principio:** La elección entre Peering y TGW no es técnica sino arquitectónica. Peering es simple y barato para escenarios pequeños. TGW es la base de cualquier Landing Zone empresarial donde la gobernanza y la segmentación del tráfico son requisitos de primer orden.

---

> **Siguiente:** [Sección 6 — Conectividad Híbrida →](./06_conectividad_hibrida.md)
