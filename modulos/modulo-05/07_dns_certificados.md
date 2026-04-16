# Sección 7 — DNS y Certificados

> [← Sección anterior](./06_conectividad_hibrida.md) | [Volver al índice →](./README.md)

---

## 7.1 Route 53: El Sistema de Nombres de AWS

DNS (Domain Name System) traduce nombres de dominio legibles por humanos en direcciones IP. Sin DNS, usuarios y servicios tendrían que recordar IPs en lugar de `api.empresa.com`. Route 53 es el servicio DNS gestionado de AWS: altamente disponible, escalable y con SLA del 100%.

En Terraform, `aws_route53_zone` es el recurso base — el contenedor de todos los registros DNS de un dominio:

```hcl
# Zona pública: visible desde Internet
resource "aws_route53_zone" "public" {
  name = "empresa.com"
}

# Zona privada: solo visible dentro de las VPCs asociadas
resource "aws_route53_zone" "private" {
  name = "internal.empresa.com"

  vpc {
    vpc_id = aws_vpc.main.id
  }
}
```

**Hosted Zone Pública:** resuelve nombres desde cualquier lugar de Internet. Para sitios web, APIs públicas y servicios expuestos. Coste: $0.50/mes por zona.

**Hosted Zone Privada:** solo resuelve dentro de las VPCs asociadas. Invisible desde Internet. Perfecta para microservicios internos: `db.internal`, `cache.internal`, `auth.internal`. Los equipos pueden usar nombres descriptivos sin exponerlos al exterior.

---

## 7.2 Tipos de Registro DNS

Cada `aws_route53_record` requiere: `zone_id`, `name` (subdominio o apex), `type` y los datos del registro:

| Tipo | Función | Ejemplo |
|------|---------|---------|
| `A` | Nombre → IPv4 | `api.empresa.com` → `10.0.1.5` |
| `AAAA` | Nombre → IPv6 | `api.empresa.com` → `2001:db8::1` |
| `CNAME` | Alias a otro nombre | `www` → `empresa.com` |
| `MX` | Servidor de correo | Prioridad + servidor SMTP |
| `TXT` | Texto libre | Verificación SPF, DKIM, ACM |
| `NS` | Name Servers | Delegación a subdominios |

---

## 7.3 La Joya de la Corona: ALIAS vs. CNAME

Este es el punto más importante de Route 53 que la mayoría no conoce hasta que lo necesita:

> **Para recursos nativos de AWS (ALB, CloudFront, S3), siempre usa registros ALIAS en lugar de CNAME.**

| | CNAME | ALIAS (solo Route 53) |
|--|-------|----------------------|
| Funciona en el Apex (`empresa.com`) | ❌ No (limitación DNS estándar) | ✅ Sí |
| Coste de consultas DNS | Cobra extra (resolución en dos pasos) | **Gratuito** para recursos AWS |
| Actualización automática de IPs | No (manual) | Sí (sigue las IPs del ALB/CF automáticamente) |
| Velocidad de resolución | Dos pasos | Directo |

```hcl
# Registro ALIAS al ALB (recomendado para AWS)
resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "app.empresa.com"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name      # DNS del ALB
    zone_id                = aws_lb.app.zone_id        # Hosted Zone ID del ALB
    evaluate_target_health = true                      # Hereda el estado de salud del ALB
  }
}
```

Con `evaluate_target_health = true`, si todos los targets del ALB están unhealthy, Route 53 devuelve SERVFAIL en lugar de redirigir a un ALB que no funciona. Crucial para failover.

---

## 7.4 Políticas de Enrutamiento: Simple, Weighted y Latency

Route 53 puede hacer mucho más que simplemente resolver nombres — puede tomar decisiones de enrutamiento basadas en peso, latencia o salud:

**Weighted (Canary Deployments):**
```hcl
# 90% del tráfico al stack estable
resource "aws_route53_record" "stable" {
  zone_id        = aws_route53_zone.public.zone_id
  name           = "api.empresa.com"
  type           = "A"
  set_identifier = "stable"
  weighted_routing_policy { weight = 90 }

  # Para ALBs se usa alias {}, no records/ttl (un A record no acepta DNS names)
  alias {
    name                   = aws_lb.stable.dns_name
    zone_id                = aws_lb.stable.zone_id
    evaluate_target_health = true
  }
}

# 10% del tráfico al nuevo release
resource "aws_route53_record" "canary" {
  zone_id        = aws_route53_zone.public.zone_id
  name           = "api.empresa.com"
  type           = "A"
  set_identifier = "canary"
  weighted_routing_policy { weight = 10 }

  alias {
    name                   = aws_lb.canary.dns_name
    zone_id                = aws_lb.canary.zone_id
    evaluate_target_health = true
  }
}
```

**Latency (Multi-región):**
```hcl
resource "aws_route53_record" "us" {
  zone_id        = aws_route53_zone.public.zone_id
  name           = "api.empresa.com"
  type           = "A"
  set_identifier = "us-east-1"

  latency_routing_policy {
    region = "us-east-1"
  }

  alias {
    name                   = aws_lb.us.dns_name
    zone_id                = aws_lb.us.zone_id
    evaluate_target_health = true
  }
}
```

Route 53 mide la latencia desde el cliente a cada región y responde con la más rápida. Un usuario en Europa recibirá la IP del ALB en `eu-west-1` automáticamente.

---

## 7.5 Health Checks y Failover: Alta Disponibilidad DNS

Route 53 puede monitorizar la salud de tus endpoints y redirigir el tráfico automáticamente cuando detecta un fallo:

```hcl
# Health Check que verifica HTTPS en /health
resource "aws_route53_health_check" "app" {
  fqdn              = "app.empresa.com"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
}

# Registro PRIMARY con health check
resource "aws_route53_record" "primary" {
  zone_id        = aws_route53_zone.public.zone_id
  name           = "api.empresa.com"
  type           = "A"
  set_identifier = "primary"
  health_check_id = aws_route53_health_check.app.id

  failover_routing_policy { type = "PRIMARY" }

  records = ["10.0.1.100"]
  ttl     = 60
}

# Registro SECONDARY (DR) — solo se activa cuando el PRIMARY falla
resource "aws_route53_record" "secondary" {
  zone_id        = aws_route53_zone.public.zone_id
  name           = "api.empresa.com"
  type           = "A"
  set_identifier = "secondary"

  failover_routing_policy { type = "SECONDARY" }

  records = ["10.1.1.100"]   # IP del entorno de DR
  ttl     = 60
}
```

El flujo es: Route 53 realiza health checks cada 30 segundos. Si el PRIMARY falla 3 veces consecutivas, Route 53 empieza a responder con el SECONDARY automáticamente. Cuando el PRIMARY se recupera, vuelve a usarlo. Todo sin intervención humana.

---

## 7.6 DNS Privado: Resolver Endpoints para Entornos Híbridos

En entornos híbridos (VPN + Direct Connect), necesitas que el DNS fluya en ambas direcciones:

- **Inbound Endpoint:** permite que tu datacenter resuelva nombres de AWS (`db.internal.empresa.com`)
- **Outbound Endpoint:** permite que instancias EC2 resuelvan nombres de tu datacenter (`ldap.corp.local`)

```hcl
# Outbound Endpoint: EC2 puede resolver nombres on-premise
resource "aws_route53_resolver_endpoint" "outbound" {
  name      = "outbound-resolver"
  direction = "OUTBOUND"

  security_group_ids = [aws_security_group.resolver.id]

  ip_address {
    subnet_id = aws_subnet.private_a.id
  }
  ip_address {
    subnet_id = aws_subnet.private_b.id
  }
}

# Regla: reenviar .corp.local al DNS on-premise
resource "aws_route53_resolver_rule" "corp" {
  domain_name          = "corp.local"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  target_ip {
    ip = "192.168.1.53"   # DNS on-premise
  }
}
```

Las Resolver Rules pueden compartirse entre cuentas vía AWS RAM, permitiendo que una cuenta de Networking gestione toda la resolución DNS híbrida para la organización.

---

## 7.7 DNSSEC: Protección contra DNS Spoofing

Sin DNSSEC, un atacante puede realizar **DNS Cache Poisoning**: envenenar la caché del resolvedor de un ISP para redirigir `banco.com` a su propio servidor. El usuario escribe la URL correcta pero llega a una web falsa.

DNSSEC firma criptográficamente las respuestas DNS, garantizando que no han sido alteradas en tránsito:

```hcl
# KMS Key en us-east-1 (obligatorio para DNSSEC)
resource "aws_kms_key" "dnssec" {
  provider                 = aws.virginia    # DNSSEC requiere us-east-1
  description              = "KMS para DNSSEC Route 53"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
}

# Key Signing Key
resource "aws_route53_key_signing_key" "main" {
  hosted_zone_id             = aws_route53_zone.public.id
  key_management_service_arn = aws_kms_key.dnssec.arn
  name                       = "main-ksk"
}

# Activar DNSSEC en la zona
resource "aws_route53_hosted_zone_dnssec" "main" {
  hosted_zone_id = aws_route53_zone.public.id
  depends_on     = [aws_route53_key_signing_key.main]
}
```

Consideraciones: solo para zonas públicas; la KMS Key **debe** estar en `us-east-1` independientemente de dónde esté el resto de la infraestructura; hay que registrar el registro DS en el registrador del dominio para completar la cadena de confianza.

---

## 7.8 ACM: Certificados SSL/TLS Gratuitos

AWS Certificate Manager (ACM) provisiona, gestiona y **renueva automáticamente** certificados SSL/TLS sin coste para servicios integrados (ALB, CloudFront, API Gateway, NLB).

La clave es la **validación DNS**: ACM genera un registro CNAME de validación y, si ese registro existe en Route 53, la validación y renovación son completamente automáticas:

```hcl
# Solicitar certificado wildcard para todos los subdominios
resource "aws_acm_certificate" "main" {
  domain_name       = "empresa.com"
  validation_method = "DNS"   # Siempre DNS, nunca EMAIL

  subject_alternative_names = [
    "*.empresa.com"   # Wildcard cubre todos los subdominios
  ]

  lifecycle {
    create_before_destroy = true   # Evita downtime al renovar
  }
}

# Crear registros de validación DNS automáticamente
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.public.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# Esperar a que ACM confirme la validación antes de continuar
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
```

El bloque `for_each` es elegante: itera sobre `domain_validation_options` (que ACM genera al crear el certificado) y crea automáticamente un registro DNS por cada dominio validado. Cuando ACM necesita renovar, el registro DNS ya está presente y la renovación es transparente.

---

## 7.9 Certificados para CloudFront: La Trampa de us-east-1

> ⚠️ **CloudFront SOLO acepta certificados ACM de la región `us-east-1`**, independientemente de dónde esté el resto de tu infraestructura.

Si tu aplicación está en `eu-west-1` y creas el certificado ahí, CloudFront lo rechazará. La solución es un **provider alias**:

```hcl
# Provider alias para us-east-1
provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}

# Certificado en us-east-1 (obligatorio para CloudFront)
resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.virginia    # ← Clave: usa el provider de Virginia
  domain_name       = "cdn.empresa.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Los registros de validación pueden estar en cualquier región
resource "aws_route53_record" "cf_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.public.zone_id   # La zona está donde esté (R53 es global)
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}
```

Un único `terraform apply` gestiona las dos regiones simultáneamente. El certificado nace en us-east-1, la validación DNS se crea donde esté la zona Route 53, y CloudFront puede usarlo.

---

## 7.10 Importar Certificados Externos

Si tu organización usa certificados de una CA propia (PKI corporativa) o comercial (DigiCert, Sectigo), puedes importarlos a ACM para usarlos con ALB y NLB:

```hcl
resource "aws_acm_certificate" "external" {
  certificate_body  = file("${path.module}/certs/certificate.pem")
  private_key       = file("${path.module}/certs/private_key.pem")
  certificate_chain = file("${path.module}/certs/chain.pem")
}
```

> **Limitación importante:** los certificados importados NO se renuevan automáticamente. Debes reimportarlos antes de que expiren. Además, la clave privada queda almacenada en el Terraform state file. Prefiere ACM nativo siempre que sea posible; usa importación solo cuando la CA corporativa lo exige o hay requisitos regulatorios específicos.

---

## 7.11 Delegación de Subdominios Multi-Cuenta

En organizaciones con múltiples cuentas AWS, cada equipo puede gestionar su propio subdominio de forma autónoma:

```
cuenta-raiz.com (empresa.com)
    ├── NS record → dev.empresa.com → Name Servers de la cuenta de Dev
    ├── NS record → prod.empresa.com → Name Servers de la cuenta de Prod
    └── NS record → sec.empresa.com → Name Servers de la cuenta de Security
```

```hcl
# En la cuenta hijo (Dev): crear zona para dev.empresa.com
resource "aws_route53_zone" "dev" {
  name = "dev.empresa.com"
}

# Output: los 4 Name Servers generados por Route 53
output "dev_name_servers" {
  value = aws_route53_zone.dev.name_servers
}

# En la cuenta padre: delegar con registro NS
resource "aws_route53_record" "dev_delegation" {
  zone_id = aws_route53_zone.root.zone_id
  name    = "dev.empresa.com"
  type    = "NS"
  ttl     = 172800   # 48 horas (estándar para delegación)
  records = var.dev_name_servers   # Los 4 NS de la cuenta Dev
}
```

Cada equipo tiene autonomía total sobre su subdominio. La cuenta raíz solo gestiona la delegación — no necesita conocer los registros específicos del equipo de Dev.

---

## 7.12 Buenas Prácticas: DNS y Certificados en Producción

| Área | Práctica |
|------|----------|
| **Registros DNS** | ALIAS > CNAME para recursos AWS; TTL bajo (60s) en registros de failover |
| **Health Checks** | Activos en todos los registros críticos con `evaluate_target_health = true` |
| **Certificados** | Siempre validación DNS (no EMAIL); wildcard `*.dominio` + apex en SANs |
| **Lifecycle** | `create_before_destroy = true` en certificados — evita downtime al renovar |
| **CloudFront** | Certificados siempre en `us-east-1` con provider alias |
| **Seguridad** | DNSSEC en zonas públicas; zonas privadas para servicios internos |
| **Híbrido** | Resolver Endpoints para DNS on-premise; Rules compartidas vía RAM |
| **Privacidad** | Nunca guardar `private_key` en state si se puede evitar; usa ACM nativo |

---

## 7.13 Resumen: DNS y Certificados Completos

```
Route 53
 ├── aws_route53_zone          → Zona pública o privada (VPC asociada)
 ├── aws_route53_record        → A, AAAA, CNAME, ALIAS, MX, TXT, NS
 │    ├── routing_policy       → Simple, Weighted, Latency, Failover, Geolocation
 │    └── alias {}             → Resolución directa a recursos AWS (sin coste)
 ├── aws_route53_health_check  → Monitoreo HTTP/HTTPS/TCP con failover automático
 ├── aws_route53_resolver_endpoint → DNS híbrido: Inbound + Outbound
 └── aws_route53_hosted_zone_dnssec → Firma criptográfica contra spoofing

ACM
 ├── aws_acm_certificate           → Solicitar con validation_method = "DNS"
 ├── aws_route53_record (cert)     → Registros de validación con for_each automático
 ├── aws_acm_certificate_validation → Esperar validación antes de adjuntar al ALB
 └── provider alias (virginia)     → Certificados para CloudFront en us-east-1
```

> **Principio:** El DNS es la guía telefónica de Internet y los certificados son los carnets de identidad de los servidores. Sin DNS correcto, nadie llega a tus servicios. Sin certificados válidos, los navegadores advierten a los usuarios de no confiar en ellos. Terraform permite gestionar ambos de forma declarativa, reproducible y con renovación automática — eliminando por completo la deuda técnica de los certificados expirados.

---

> **[← Volver al índice del Módulo 5](./README.md)**
