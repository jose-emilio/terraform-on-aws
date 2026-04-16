# Sección 2 — Internet Gateway, NAT y VPC Endpoints

> [← Sección anterior](./01_vpc_subredes.md) | [Siguiente →](./03_enrutamiento.md)

---

## 2.1 El Puente al Mundo: `aws_internet_gateway`

Una VPC recién creada está completamente aislada. Para que los recursos en subredes públicas puedan comunicarse con Internet —tanto para recibir tráfico como para iniciarlo— necesitas un **Internet Gateway (IGW)**.

El IGW es un recurso que escala horizontalmente de forma automática, tolera fallos sin intervención y no tiene coste por hora. Solo pagas por los datos transferidos.

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "igw-produccion"
  }
}
```

Un detalle importante: crear el IGW y asociarlo a la VPC no es suficiente. Para que una subred sea realmente "pública" debes:
1. Tener un IGW adjunto a la VPC ✓
2. Tener una ruta `0.0.0.0/0 → IGW` en la tabla de rutas de la subred ← (sección 3)
3. Los recursos en esa subred deben tener IP pública (o EIP)

---

## 2.2 Elastic IPs: Direcciones IP Fijas en la Nube

Una **Elastic IP (EIP)** es una dirección IPv4 pública estática asociada a tu cuenta. A diferencia de las IPs públicas normales que cambian cuando paras una instancia, la EIP es fija.

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"   # "vpc" es obligatorio en VPCs; el valor antiguo "standard" está deprecado

  tags = {
    Name = "eip-nat-az-a"
  }
}
```

> **Coste trampa:** AWS cobra **$0.005/hora (~$3.60/mes)** por una EIP que NO está asociada a un recurso en uso. Si creas EIPs de más o dejas instancias paradas, el coste se acumula silenciosamente. Terraform te ayuda aquí: si la EIP y el NAT Gateway están en el mismo código, ambos se crean y destruyen juntos.

---

## 2.3 NAT Gateway: Acceso a Internet sin Exposición

Las instancias en subredes **privadas** necesitan acceder a Internet (para descargar parches, conectarse a APIs externas) pero no deben ser accesibles desde Internet. El **NAT Gateway** resuelve exactamente esto:

```
Internet ←→ IGW ←→ Subred Pública ←→ NAT Gateway ←→ Subred Privada ←→ EC2
                                       (Traduce IPs)
```

El tráfico sale desde la instancia privada, pasa por el NAT Gateway (que está en una subred pública y tiene una EIP), y llega a Internet. Las respuestas vuelven el mismo camino. Las conexiones iniciadas desde Internet hacia la instancia privada son descartadas.

**Requisito crítico:** El NAT Gateway necesita:
1. Estar en una **subred pública** (que tiene ruta al IGW)
2. Tener una **Elastic IP** asignada
3. Que la subred privada tenga una **ruta** `0.0.0.0/0 → NAT GW`

---

## 2.4 NAT Zonal vs. NAT Regional

AWS ofrece dos modos para NAT Gateway mediante el argumento `availability_mode`, con implicaciones distintas en coste y disponibilidad:

**Opción A — NAT Zonal (un NAT por AZ):**

```hcl
resource "aws_nat_gateway" "zonal" {
  for_each      = toset(["us-east-1a", "us-east-1b", "us-east-1c"])
  subnet_id     = aws_subnet.public[each.key].id
  allocation_id = aws_eip.nat[each.key].id

  tags = { Name = "nat-${each.key}" }
}
```

Pros: alta disponibilidad, sin coste de tráfico cross-AZ (el tráfico permanece en su AZ).

Contras: 3 NAT Gateways = ~$32/mes × 3 = ~**$96/mes**.

**Opción B — NAT Regional (un solo NAT para toda la región altamente disponible entre AZs):**

```hcl
resource "aws_nat_gateway" "regional" {
  connectivity_type = "public"
  availability_mode = "regional"
  vpc_id            = var.vpc_id

  
  tags = { Name = "nat-regional" }
}
```

Pros:  ~**$32/mes** por cada AZ donde viva.

Contras: si alguna de las AZs donde vive el NAT falla, todas las privadas pierden salida a Internet.

---

## 2.5 Evitando el "NAT Tax": VPC Endpoints

Este es uno de los ahorros más importantes y menos conocidos en AWS. Todo tráfico que va de EC2 a S3 o DynamoDB pasando por el NAT Gateway genera **cargos por GB**:

```
Sin Endpoint:   EC2 → NAT ($0.045/GB) → IGW → S3
Con Endpoint:   EC2 → VPC Endpoint → S3  ($0.00 adicional)
```

1 TB/mes de tráfico a S3 pasando por NAT = **$45 innecesarios**. Un Gateway Endpoint para S3 lo elimina completamente.

**Tipos de VPC Endpoint:**

| Tipo | Servicios | Coste | Cómo funciona |
|------|-----------|-------|---------------|
| **Gateway** | S3, DynamoDB | **Gratis** | Se añade a la route table como entrada |
| **Interface** | EC2, SSM, SQS, SNS, KMS... | ~$7.20/mes | Crea una ENI con IP privada en tu subred |

```hcl
# Gateway Endpoint para S3 — SIEMPRE debería estar activo
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# Interface Endpoint para SSM (permite gestionar EC2 sin bastion)
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(aws_subnet.private)[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true   # Resuelve ssm.us-east-1.amazonaws.com a IPs privadas
}
```

Con `private_dns_enabled = true`, tu código no necesita cambiar nada: el mismo nombre de host `ssm.amazonaws.com` ahora resuelve a una IP privada dentro de la VPC.

---

## 2.6 NAT Instance: La Alternativa de Bajo Coste para Dev

Para entornos de desarrollo y sandbox donde el coste importa más que la disponibilidad gestionada, una instancia EC2 puede hacer las veces de NAT Gateway a una fracción del precio:

```hcl
resource "aws_instance" "nat" {
  ami                    = var.nat_ami_id       # AMI con iptables/NAT configurado
  instance_type          = "t3.nano"            # ~$3-8/mes vs $32 del NAT Gateway
  subnet_id              = aws_subnet.public["us-east-1a"].id
  source_dest_check      = false                # CRÍTICO: desactiva el filtro de IPs ajenas
  vpc_security_group_ids = [aws_security_group.nat.id]

  tags = { Name = "nat-instance" }
}

resource "aws_eip" "nat_instance" {
  instance = aws_instance.nat.id
  domain   = "vpc"
}
```

El argumento `source_dest_check = false` es la clave. Por defecto, EC2 descarta paquetes que no tienen su propia IP como origen o destino. Al desactivarlo, la instancia puede reenviar paquetes de otras IPs — exactamente lo que necesita un router NAT.

> **Comparativa:** NAT Instance t3.nano ≈ $4/mes vs NAT Gateway ≈ $32/mes. Pero: sin HA automática, requiere gestión de parches del SO y no escala automáticamente. Solo usar en dev/sandbox.

---

## 2.7 IPv6 sin NAT: Egress-Only Internet Gateway

En IPv6 no existe NAT: cada recurso tiene una dirección globalmente única y enrutable. Esto simplifica la red pero requiere un mecanismo para filtrar conexiones entrantes no deseadas.

El **Egress-Only Internet Gateway (EIGW)** resuelve esto: permite tráfico de salida IPv6 pero bloquea conexiones entrantes que no fueron iniciadas por el recurso.

```hcl
resource "aws_egress_only_internet_gateway" "eigw" {
  vpc_id = aws_vpc.main.id
}

# Ruta IPv6 de salida hacia el EIGW
resource "aws_route" "ipv6_egress" {
  route_table_id              = aws_route_table.private.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw.id
}
```

Ventajas sobre NAT para IPv6:
- Sin coste de EIP (el EIGW no necesita IP pública fija)
- Sin coste de procesamiento de NAT Gateway
- Filtrado stateful nativo — solo pasa el tráfico de respuesta
- Configuración mínima: solo `vpc_id` y una ruta `::/0`

---

## 2.8 Lista de Control: Conectividad de Red

Antes de verificar por qué un recurso no tiene conectividad a Internet, repasa este checklist:

| ✓ | Elemento | Verificación |
|---|----------|-------------|
| ✓ | **IGW adjunto** | La VPC tiene un `aws_internet_gateway` asociado |
| ✓ | **Ruta pública** | Tabla de rutas pública tiene `0.0.0.0/0 → IGW` |
| ✓ | **NAT tiene ruta al IGW** | La subred donde vive el NAT tiene ruta `0.0.0.0/0 → IGW` |
| ✓ | **Ruta privada** | Tabla de rutas privada tiene `0.0.0.0/0 → NAT GW` |
| ✓ | **EIP no huérfana** | EIPs asociadas a un recurso activo (evitar coste) |
| ✓ | **S3 sin NAT** | Gateway Endpoint para S3 activo (ahorro de NAT Tax) |

Errores comunes:
- NAT Gateway en subred privada (no funciona — necesita subred pública con acceso al IGW)
- S3 pasando por NAT (paga $0.045/GB innecesariamente)
- EIPs sin asociar (genera coste sin utilidad)
- NAT Zonal en dev (sobrecosto de 3x sin justificación)

---

## 2.9 Resumen: Los Guardianes de la Conectividad

```
Internet
    ↕ (bidireccional)
Internet Gateway (aws_internet_gateway)   → Sin coste por hora, escala automático
    ↕
Subredes Públicas (con EIPs opcionales)
    ↕ (solo salida)
NAT Gateway (aws_nat_gateway + EIP)       → Regional $32/mes | Zonal $96/mes (3 AZs)
    ↕
Subredes Privadas
    ↕ (directo, sin Internet)
VPC Endpoints (aws_vpc_endpoint)          → Gateway (S3/DynamoDB): gratis
                                             Interface (SSM/SQS...): $7.20/mes
```

> **Principio FinOps:** Activa siempre los Gateway Endpoints para S3 y DynamoDB desde el primer día — son gratuitos y pueden ahorrarte decenas de dólares al mes por cada TB de tráfico que evitas pasar por NAT.

---

> **Siguiente:** [Sección 3 — Tablas de Rutas y Enrutamiento →](./03_enrutamiento.md)
