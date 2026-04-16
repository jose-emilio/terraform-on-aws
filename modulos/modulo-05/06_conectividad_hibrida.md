# Sección 6 — Conectividad Híbrida

> [← Sección anterior](./05_interconectividad.md) | [Siguiente →](./07_dns_certificados.md)

---

## 6.1 La Nube Híbrida: Extendiendo el Datacenter a AWS

En la mayoría de organizaciones, la migración a la nube no es un evento puntual sino un proceso gradual. Durante años, o incluso permanentemente, coexisten recursos en el datacenter físico y en AWS. Esta arquitectura se llama **nube híbrida**.

Las razones para mantener conectividad híbrida son variadas:
- Migración gradual donde algunos servicios aún viven on-premise
- Cumplimiento regulatorio que obliga a mantener ciertos datos en instalaciones propias
- Servicios legacy que no pueden moverseala nube
- Conectividad de acceso remoto para empleados

Dos caminos principales para conectar datacenter con AWS:

| | VPN Site-to-Site | Direct Connect (DX) |
|--|-----------------|---------------------|
| Medio | Túnel IPsec sobre Internet público | Fibra óptica dedicada |
| Despliegue | Minutos | Semanas |
| Latencia | Variable (depende de Internet) | Consistente y baja (<5ms) |
| Ancho de banda | Hasta 1.25 Gbps/túnel | 1, 10, 100 Gbps |
| Coste | Bajo | Alto (puerto + partner) |
| Cifrado | Nativo (IPsec) | No incluido por defecto |
| **Ideal para** | Inicio, backup, cargas no críticas | Producción crítica, alto volumen |

---

## 6.2 Los Pilares de la VPN: VGW y CGW

Toda conexión VPN en AWS requiere dos extremos lógicos:

**Virtual Private Gateway (VGW):** el extremo de AWS. Se vincula a una VPC específica y actúa como el punto de terminación de los túneles VPN del lado de Amazon.

**Customer Gateway (CGW):** la representación del router físico on-premise dentro del modelo de Terraform. No es el router en sí, sino un objeto en AWS que almacena sus parámetros (IP pública y ASN de BGP).

```hcl
# Virtual Private Gateway — lado AWS
resource "aws_vpn_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "vpn-gateway-main" }
}

# Customer Gateway — router del datacenter de Madrid
resource "aws_customer_gateway" "onprem" {
  bgp_asn    = 65000           # ASN del AS del datacenter
  ip_address = "203.0.113.10"  # IP pública del router on-premise
  type       = "ipsec.1"       # Siempre "ipsec.1"

  tags = { Name = "cgw-datacenter-madrid" }
}
```

---

## 6.3 Site-to-Site VPN: El Túnel IPsec

Con VGW y CGW creados, `aws_vpn_connection` establece los túneles. AWS crea automáticamente **dos túneles IPsec redundantes** en AZs distintas para Alta Disponibilidad:

```hcl
resource "aws_vpn_connection" "main" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.onprem.id
  type                = "ipsec.1"
  static_routes_only  = false   # false = usar BGP (recomendado)

  # Configuración de los dos túneles HA
  tunnel1_inside_cidr   = "169.254.10.0/30"
  tunnel1_preshared_key = var.tunnel1_psk
  tunnel2_inside_cidr   = "169.254.10.4/30"
  tunnel2_preshared_key = var.tunnel2_psk

  tags = { Name = "vpn-datacenter-madrid" }
}
```

**BGP vs. Rutas estáticas:**
- BGP (`static_routes_only = false`): el router on-premise y el VGW intercambian rutas automáticamente. Cuando añades una nueva subred on-premise, se anuncia a AWS sin tocar Terraform.
- Rutas estáticas: defines los CIDRs manualmente en Terraform. Más simple pero más trabajo de mantenimiento.

Siempre usa BGP en producción si tu equipo de red lo soporta.

---

## 6.4 VPN Acelerada con Transit Gateway y Global Accelerator

La VPN estándar enruta el tráfico por Internet público — múltiples saltos entre ISPs con latencia variable. **Accelerated VPN** entra a la red backbone de AWS en el PoP más cercano y viaja por fibra privada hasta tu VPC:

```
VPN Normal:     Datacenter → Múltiples ISPs → AWS Edge → VPC
VPN Acelerada:  Datacenter → PoP de AWS más cercano → Backbone AWS → Transit Gateway → VPC
```

```hcl
resource "aws_vpn_connection" "accel" {
  transit_gateway_id  = aws_ec2_transit_gateway.main.id   # TGW obligatorio (no VGW)
  customer_gateway_id = aws_customer_gateway.onprem.id
  type                = "ipsec.1"
  enable_acceleration = true                              # Activa Global Accelerator
  static_routes_only  = false

  tunnel1_inside_cidr   = "169.254.10.0/30"
  tunnel1_preshared_key = var.tunnel1_psk
  tunnel2_inside_cidr   = "169.254.10.4/30"
  tunnel2_preshared_key = var.tunnel2_psk

  tags = { Name = "vpn-accel-bgp" }
}

# Asociar el TGW a la VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  subnet_ids         = [aws_subnet.private.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.main.id
}

# Ruta en la VPC para llegar al datacenter via TGW
resource "aws_route" "to_onprem" {
  route_table_id         = aws_vpc.main.main_route_table_id
  destination_cidr_block = "192.168.0.0/16"   # CIDR del datacenter
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}
```

La **ventaja de VPN sobre TGW** frente a VPN sobre VGW: cuando añades una nueva VPC al TGW, esa VPC obtiene acceso al datacenter on-premise automáticamente, sin tocar la configuración VPN.

---

## 6.5 Client VPN: Acceso Remoto para Usuarios

A diferencia de Site-to-Site (red a red), **Client VPN** conecta usuarios individuales a los recursos de AWS. Ideal para equipos en teletrabajo:

```hcl
resource "aws_ec2_client_vpn_endpoint" "remote_access" {
  description            = "VPN acceso remoto empleados"
  server_certificate_arn = aws_acm_certificate.vpn_server.arn
  client_cidr_block      = "10.255.0.0/16"   # IPs asignadas a los clientes VPN

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.vpn_ca.arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.vpn.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.vpn.name
  }
}

# Asociar el endpoint a subredes
resource "aws_ec2_client_vpn_network_association" "subnet" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.remote_access.id
  subnet_id              = aws_subnet.private.id
}
```

Soporta autenticación mediante certificados mutuos TLS, Active Directory o SAML (SSO). Los usuarios conectados heredan acceso a las subredes asociadas.

---

## 6.6 Direct Connect: La Línea Dedicada

Direct Connect establece una conexión física entre tu datacenter y una instalación de AWS (a través de un partner de colocación). Es la opción para cargas críticas que requieren latencia predecible y ancho de banda garantizado.

> **Importante:** Terraform gestiona la capa **lógica** de Direct Connect (interfaces virtuales, gateways), pero **no el cable físico**. El aprovisionamiento físico requiere coordinación con AWS y el partner de colocación — puede tardar semanas.

```hcl
# DX Gateway: recurso global que conecta el DX a VPCs en múltiples regiones
resource "aws_dx_gateway" "main" {
  name            = "my-dx-gateway"
  amazon_side_asn = "64512"
}

# Asociar el DX Gateway al VGW de la VPC
resource "aws_dx_gateway_association" "main" {
  dx_gateway_id         = aws_dx_gateway.main.id
  associated_gateway_id = aws_vpn_gateway.main.id
}

# Private Virtual Interface: acceso a recursos privados dentro de VPCs
resource "aws_dx_private_virtual_interface" "private" {
  connection_id  = "dxcon-abc12345"    # ID de la conexión física (del partner)
  name           = "vif-private-prod"
  vlan           = 100
  bgp_asn        = 65000
  dx_gateway_id  = aws_dx_gateway.main.id
  address_family = "ipv4"
}
```

**Tipos de interfaces virtuales (VIF):**
- **Private VIF:** accede a recursos privados dentro de VPCs (EC2, RDS). Usa VLAN ID y BGP.
- **Public VIF:** accede a servicios públicos de AWS (S3, DynamoDB) sin pasar por Internet. El tráfico viaja por la fibra DX directamente a los endpoints de AWS.

---

## 6.7 VPN sobre Direct Connect: Cifrado End-to-End

> ⚠️ **Direct Connect NO cifra el tráfico por defecto.** La fibra es privada pero el tráfico viaja en texto plano.

Para cumplir PCI-DSS, HIPAA o SOC2, debes añadir una capa de cifrado IPsec encima:

| | DX Solo | DX + VPN |
|--|---------|---------|
| Privacidad | Fibra física privada | Fibra + cifrado AES-256 |
| Tráfico | En texto plano | Cifrado end-to-end |
| Compliance | General | PCI-DSS, HIPAA, SOC2 ✅ |
| Rendimiento | Máximo (sin overhead) | Hasta 1.25 Gbps/túnel |

La implementación combina una Private VIF con una conexión VPN IPsec que usa esa VIF como transporte.

---

## 6.8 Resiliencia: VPN como Backup de Direct Connect

El patrón de mayor disponibilidad para conectividad híbrida: **DX como primario + VPN como failover automático mediante BGP**:

```
Estado normal:    Datacenter → DX (baja latencia, alto BW) → VPC
                  VPN en standby, rutas aprendidas por BGP

Failover DX:      BGP detecta pérdida de sesión DX
                  Conmuta automáticamente a VPN (más lento pero funcional)
                  Sin intervención manual necesaria
```

BGP gestiona la preferencia de rutas: el DX anuncia rutas con AS_PATH corto (mayor preferencia). Si el DX falla, las rutas dejan de anunciarse y BGP conmuta automáticamente a las rutas de la VPN. Cuando el DX se recupera, las rutas se re-anuncian y el tráfico vuelve a la fibra.

---

## 6.9 Observabilidad de Conexiones Híbridas

No basta con crear la infraestructura — necesitas saber cuándo falla antes de que impacte al negocio:

```hcl
# Alarma: túnel VPN caído
resource "aws_cloudwatch_metric_alarm" "vpn_tunnel_down" {
  alarm_name          = "vpn-tunnel-state"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Average"
  threshold           = 1   # 0 = caído, 1 = activo

  dimensions = {
    VpnId = aws_vpn_connection.main.id
  }

  alarm_actions = [aws_sns_topic.alertas.arn]
}
```

**Métricas clave a monitorear:**

| Conexión | Métrica | Significado |
|----------|---------|-------------|
| VPN | `TunnelState` | 0 = caído, 1 = activo |
| VPN | `TunnelDataIn/Out` | Bytes transferidos |
| DX | `ConnectionState` | Estado de la conexión física |
| DX | `ConnectionBpsEgress/Ingress` | Ancho de banda utilizado |
| DX | `VirtualInterfaceBps` | Tráfico por VIF |

---

## 6.10 Resumen: Mapa Completo de Conectividad Híbrida

```
Datacenter On-Premise
    │
    ├──→ VPN Site-to-Site (aws_vpn_connection)
    │       └── IPsec sobre Internet, dos túneles HA, BGP/estático
    │
    ├──→ VPN Acelerada (enable_acceleration = true + TGW)
    │       └── PoP → Backbone AWS → menor latencia
    │
    ├──→ AWS Client VPN (aws_ec2_client_vpn_endpoint)
    │       └── Usuarios remotos, OpenVPN, certificados/AD/SAML
    │
    └──→ Direct Connect (aws_dx_gateway + VIFs)
            ├── Fibra dedicada, latencia baja, alto BW
            ├── Private VIF → recursos privados en VPCs
            └── Public VIF → servicios públicos de AWS sin Internet
```

| Patrón | Cuándo usarlo |
|--------|--------------|
| VPN Simple | Inicio, dev, cargas no críticas o como backup de DX |
| VPN Acelerada + TGW | Cuando la latencia importa y tienes múltiples VPCs |
| Client VPN | Acceso remoto de usuarios individuales |
| Direct Connect | Producción crítica, regulación, alto volumen de datos |
| DX + VPN Backup | Máxima disponibilidad con failover automático |
| VPN sobre DX | Cuando DX es obligatorio pero también se requiere cifrado |

> **Principio:** La conectividad híbrida es un espectro. Empieza con VPN (rápido y barato) y evoluciona a Direct Connect cuando los requisitos de latencia, cumplimiento o ancho de banda lo justifiquen. El patrón DX primario + VPN backup es el estándar de la industria para entornos de producción críticos.

---

> **Siguiente:** [Sección 7 — DNS y Certificados →](./07_dns_certificados.md)
