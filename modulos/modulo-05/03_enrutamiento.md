# Sección 3 — Tablas de Rutas y Enrutamiento

> [← Sección anterior](./02_gateways_endpoints.md) | [Siguiente →](./04_sg_nacl.md)

---

## 3.1 El Cerebro de la Red: `aws_route_table`

Si la VPC es el terreno y las subredes son los barrios, las **tablas de rutas** son los mapas de carreteras. Cada subred consulta su tabla de rutas para decidir a dónde enviar cada paquete.

Una Route Table es un conjunto de reglas (`rutas`) que determinan hacia dónde se dirige el tráfico de red. Cada regla tiene dos partes:
- **Destino (`destination_cidr_block`):** el rango de IPs de destino — quién va a recibir el paquete
- **Target (`gateway_id`, `nat_gateway_id`, etc.):** el recurso que procesará el tráfico — por dónde sale

```hcl
# Crear la tabla de rutas (contenedor vacío)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "public-rt"
  }
}
```

> **Mejor práctica:** No definas rutas inline dentro del bloque `aws_route_table`. Usa recursos `aws_route` independientes para poder añadir o quitar rutas sin recrear la tabla entera.

---

## 3.2 Micro-gestión de Caminos: `aws_route`

Separar las rutas de la tabla es el estándar profesional. Permite gestionar cada ruta como un recurso independiente con su propio ciclo de vida:

```hcl
# Ruta a Internet via IGW (para subredes públicas)
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

Esto significa que puedes hacer `terraform destroy` de una ruta específica sin tocar las demás rutas de la misma tabla. Con rutas inline, cambiar cualquier ruta recrea el recurso completo.

---

## 3.3 La Ruta Implícita: El Local Route

Hay una ruta que siempre existe aunque no la declares en ningún lugar del código:

```
Destino: 10.0.0.0/16  →  Target: local
```

Toda `aws_route_table` creada por Terraform incluye automáticamente una ruta **Local** para el CIDR completo de la VPC. Esta ruta garantiza que todas las subredes dentro de la misma VPC puedan comunicarse entre sí sin configuración adicional.

No puedes borrarla ni modificarla — es inmutable. Y gracias a ella, no necesitas crear rutas manuales para que una instancia en la Subred A hable con la Subred B dentro de la misma VPC.

---

## 3.4 Activando el Tráfico: `aws_route_table_association`

Crear la tabla de rutas no es suficiente. Una subred es "pública" o "privada" dependiendo de **a qué tabla esté asociada**, no de ningún atributo propio de la subred.

Sin asociación explícita, la subred hereda la **Main Route Table** por defecto, lo que puede exponerla a rutas no deseadas:

```hcl
# Asociar cada subred pública a la tabla de rutas pública
resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
```

Cada subred debe tener su propia asociación explícita. Es un recurso 1:1 — una subred solo puede estar asociada a una tabla de rutas a la vez.

---

## 3.5 Main vs. Custom Route Tables: Evita Heredar Rutas Peligrosas

AWS crea automáticamente una **Main Route Table** con cada VPC. Cualquier subred sin asociación explícita la hereda. El peligro:

> Si añades una ruta `0.0.0.0/0 → IGW` a la Main Route Table, **todas** las subredes sin asociación explícita se convierten automáticamente en públicas. Un error difícil de auditar y de consecuencias graves.

| | Main Route Table | Custom Route Tables |
|--|-----------------|---------------------|
| Creación | Automática con la VPC | Tú la creas explícitamente |
| Herencia | Subredes sin asociación la heredan | Solo subredes asociadas la usan |
| Riesgo | Modificarla afecta subredes ocultas | Control total, cambios predecibles |
| Recomendación | Dejar vacía (solo local route) | Una tabla por nivel de red |

La práctica recomendada: dejar la Main RT solo con la ruta local y crear tablas Custom explícitas para cada nivel (pública, privada, datos).

---

## 3.6 Rutas a Internet: IGW vs. NAT Gateway

El destino es el mismo (`0.0.0.0/0`) pero el target cambia según el nivel de la subred:

```hcl
# Subred Pública → Internet Gateway (tráfico bidireccional)
resource "aws_route" "public_to_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Subred Privada → NAT Gateway (solo tráfico de salida)
resource "aws_route" "private_to_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
```

La diferencia clave:
- `gateway_id = IGW` → tráfico bidireccional. Las instancias deben tener IP pública para recibir conexiones entrantes.
- `nat_gateway_id = NAT` → solo salida. Las instancias privadas pueden iniciar conexiones a Internet pero no recibirlas.

---

## 3.7 Enrutamiento Complejo: Peering y Transit Gateway

La tabla de rutas es también el punto de control para conectar VPCs entre sí. Cuando el target es un Peering Connection o Transit Gateway, las reglas son las mismas:

```hcl
# Tabla privada con tres destinos simultáneos
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "private-rt" }
}

# Ruta 1: Internet via NAT Gateway
resource "aws_route" "to_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# Ruta 2: VPC remota via VPC Peering
resource "aws_route" "to_vpc_b" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = "10.1.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.ab.id
}

# Ruta 3: Servicios compartidos via Transit Gateway
resource "aws_route" "to_shared_services" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "172.16.0.0/12"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
}
```

Múltiples rutas conviven en la misma tabla. AWS usa **longest prefix match**: la ruta más específica (máscara de red más larga) tiene preferencia.

---

## 3.8 Prefix Lists: Principio DRY para CIDRs

¿Tienes múltiples tablas de rutas o Security Groups que referencian los mismos rangos de IPs? Las **Managed Prefix Lists** eliminan la duplicación:

```hcl
# Crear una Prefix List reutilizable
resource "aws_ec2_managed_prefix_list" "office" {
  name           = "office-ranges"
  address_family = "IPv4"
  max_entries    = 5

  entry {
    cidr        = "192.168.1.0/24"
    description = "Oficina Madrid"
  }

  entry {
    cidr        = "192.168.2.0/24"
    description = "Oficina Barcelona"
  }
}

# Usar la Prefix List en rutas y Security Groups
resource "aws_route" "to_office" {
  route_table_id             = aws_route_table.private.id
  destination_prefix_list_id = aws_ec2_managed_prefix_list.office.id
  transit_gateway_id         = aws_ec2_transit_gateway.hub.id
}
```

La ventaja es enorme en entornos grandes: actualizas la lista una vez y todas las rutas y SGs que la referencian se actualizan automáticamente. Añadir la oficina de Valencia es cambiar un solo recurso en lugar de editar veinte tablas de rutas.

---

## 3.9 Propagación de Rutas: BGP Dinámico

En entornos híbridos con VPN o Direct Connect, las redes on-premise cambian frecuentemente. Gestionar cientos de rutas estáticas sería insostenible. La solución es la **propagación de rutas**:

```hcl
resource "aws_route_table" "private_vpn" {
  vpc_id = aws_vpc.main.id

  # El VGW inyecta automáticamente las rutas aprendidas por BGP
  propagating_vgws = [aws_vpn_gateway.main.id]

  tags = { Name = "private-vpn-rt" }
}
```

Con `propagating_vgws`, el Virtual Private Gateway aprende rutas vía BGP desde la conexión VPN y las inyecta automáticamente en la tabla. No necesitas crear `aws_route` manuales para cada red on-premise. Las rutas estáticas y las propagadas pueden coexistir en la misma tabla.

---

## 3.10 Troubleshooting: ¿Por Qué no Hay Conectividad?

Los tres culpables más comunes cuando "la infraestructura parece estar bien pero no hay ping":

| Problema | Diagnóstico | Fix |
|---------|-------------|-----|
| **Falta de asociación** | La subred usa la Main RT por defecto, que no tiene la ruta necesaria | Verificar `aws_route_table_association` explícita |
| **Ruta Blackhole** | El recurso destino (IGW, NAT, Peering) fue eliminado pero la ruta sigue existiendo | Recrear el target o la ruta; `terraform apply` lo detecta automáticamente |
| **Conflictos de CIDR** | Dos rutas con el mismo CIDR compiten | Revisar solapamientos; AWS usa longest prefix match |

**Debugging con VPC Flow Logs:**

```hcl
resource "aws_flow_log" "vpc_reject" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "REJECT"   # Solo captura tráfico bloqueado
  iam_role_arn         = aws_iam_role.flow_log_role.arn
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type = "cloud-watch-logs"
}
```

Filtrar solo `REJECT` te muestra exactamente qué tráfico se está bloqueando y en qué ENI, sin inundar los logs con tráfico permitido normal.

**El destino Blackhole:** cuando ves una ruta en estado `blackhole` en la consola de AWS, significa que el target fue eliminado pero la ruta sigue ahí. El tráfico se descarta silenciosamente — sin mensaje de error, sin log de conexión rechazada. Si el recurso y la ruta están en el mismo código Terraform, `terraform apply` sanea la ruta automáticamente. Ventaja clave del enfoque IaC frente a cambios manuales.

---

## 3.11 Buenas Prácticas: Enrutamiento DRY y Seguro

| Práctica | Implementación |
|----------|---------------|
| **Nomenclatura descriptiva** | `public-rt`, `private-rt`, `database-rt` por función; `to_internet`, `to_vpc_b` por destino |
| **Rutas desacopladas** | Usa `aws_route` independientes, nunca inline en `aws_route_table` |
| **Prefix Lists** | Agrupa IPs repetitivas; un cambio = actualización global |
| **Mínimo privilegio** | Evita `0.0.0.0/0` en subredes que no lo necesiten; usa CIDRs específicos |
| **Main RT vacía** | Solo la ruta local; tablas Custom para cada nivel de red |
| **Flow Logs activos** | Captura REJECT para diagnóstico rápido en producción |

---

## 3.12 Resumen: El Mapa Completo de la VPC

```
1. aws_route_table        → Crea el contenedor de reglas (sin rutas aún)
2. aws_route              → Define cada camino como recurso independiente
                            (IGW, NAT GW, Peering, TGW, VGW)
3. aws_route_table_association → Vincula cada subred a su tabla correcta
```

Con este trío completo, cada paquete tiene un camino definido. El flujo es:

```
Paquete sale de EC2 → consulta Route Table de la subred → coincide con la ruta más específica → llega al target
```

> **Principio:** Las Route Tables son el sistema nervioso de tu VPC. Cada subred tiene su mapa de carreteras, y ese mapa determina si esa subred es pública, privada o aislada. Una Route Table mal configurada puede exponer recursos privados o bloquear servicios esenciales — trátalas con la misma seriedad que un Security Group.

---

> **Siguiente:** [Sección 4 — Security Groups y NACLs →](./04_sg_nacl.md)
