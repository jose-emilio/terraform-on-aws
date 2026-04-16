# Sección 4 — Security Groups y Network ACLs

> [← Sección anterior](./03_enrutamiento.md) | [Siguiente →](./05_interconectividad.md)

---

## 4.1 Security Groups: El Firewall con Estado

Si las Route Tables determinan a dónde puede ir el tráfico, los **Security Groups** determinan qué tráfico puede entrar o salir de cada recurso individual. Son el firewall virtual de EC2, RDS, ALB, Lambda en VPC y cualquier recurso que tenga una interfaz de red (ENI).

Características clave:

- **Stateful (con estado):** si permites tráfico de entrada en el puerto 443, la respuesta de salida se permite automáticamente. No necesitas reglas de retorno explícitas.
- **Solo Allow:** los SGs solo tienen reglas de permiso. Todo lo que no esté explícitamente permitido queda denegado por defecto (deny implícito).
- **Nivel de ENI:** se aplica a la interfaz de red de cada recurso. Un mismo recurso puede tener hasta 5 SGs asignados.

---

## 4.2 Reglas Inline vs. `aws_security_group_rule`

Hay dos formas de definir reglas en un Security Group. Solo una es recomendada:

| | Inline (`ingress`/`egress` dentro del SG) | Recurso independiente (`aws_security_group_rule`) |
|--|------------------------------------------|--------------------------------------------------|
| Cambiar una regla | Recrea el SG completo | Solo afecta esa regla |
| Dependencias circulares | Riesgo alto | Sin riesgo |
| Flexibilidad | Baja | Alta |
| **Recomendación** | **Evitar** | **Usar siempre** |

```hcl
# Crear el SG sin reglas inline
resource "aws_security_group" "web" {
  name   = "web-sg"
  vpc_id = aws_vpc.main.id
}

# Regla de entrada: HTTPS desde Internet
resource "aws_security_group_rule" "web_ingress_https" {
  type              = "ingress"
  security_group_id = aws_security_group.web.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Regla de salida: todo permitido
resource "aws_security_group_rule" "web_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.web.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"   # -1 significa "todos los protocolos"
  cidr_blocks       = ["0.0.0.0/0"]
}
```

---

## 4.3 El Patrón Sándwich: ALB → EC2

Este es el patrón de diseño más importante para aplicaciones web: **ningún recurso backend debe ser accesible directamente desde Internet**. Todo el tráfico debe pasar por el balanceador de carga (ALB).

```
Internet → ALB (puerto 443) → EC2 (puerto 8080)
           SG del ALB         SG de la EC2
           abierto al mundo    SOLO acepta del SG del ALB
```

```hcl
# SG del ALB: acepta tráfico de Internet en 443
resource "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# SG de la EC2: SOLO acepta del SG del ALB
resource "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group_rule" "app_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.alb.id   # ← Clave: referencia al SG, no a IPs
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
}
```

El argumento `source_security_group_id` es poderoso: permite a EC2 recibir tráfico de cualquier recurso que pertenezca al SG del ALB, independientemente de su IP. Cuando escalas horizontalmente y añades más instancias ALB, no necesitas actualizar el SG de la EC2 — la referencia al SG es dinámica.

---

## 4.4 Patrón de Auto-Referencia (Self-Reference)

Para clusters donde los nodos necesitan comunicarse entre sí (ECS, Kafka, Elasticsearch), el patrón `self = true` es la solución elegante:

```hcl
resource "aws_security_group" "cluster" {
  name   = "cluster-sg"
  vpc_id = aws_vpc.main.id
}

# Los miembros del cluster se hablan entre sí sin restricción
resource "aws_security_group_rule" "cluster_self" {
  type              = "ingress"
  security_group_id = aws_security_group.cluster.id
  self              = true    # "acepta tráfico del mismo SG"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
}
```

`self = true` significa "acepta tráfico de cualquier recurso que también tenga este SG asignado". Todos los nodos del cluster comparten el mismo SG, por lo que se comunican libremente entre sí, pero ningún recurso externo puede acceder a los puertos del cluster sin ser añadido a ese SG explícitamente.

---

## 4.5 Dynamic Blocks: Generando Reglas desde una Lista

Cuando necesitas el mismo SG con múltiples puertos (microservicio que expone HTTPS, gRPC, métricas Prometheus), en lugar de repetir el mismo bloque N veces, usa `dynamic`:

```hcl
variable "allowed_ports" {
  type = list(object({ port = number, proto = string }))
  default = [
    { port = 80,   proto = "tcp" },
    { port = 443,  proto = "tcp" },
    { port = 9090, proto = "tcp" },   # Prometheus metrics
  ]
}

resource "aws_security_group" "dynamic_sg" {
  name   = "dynamic-sg"
  vpc_id = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.allowed_ports
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.proto
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}
```

Añadir un nuevo puerto es tan simple como añadir un elemento a la lista `allowed_ports`. Terraform calcula el diff y solo añade la regla nueva — no recrea el SG completo.

---

## 4.6 Delete Timeout: Robustez para Pipelines CI/CD

Un escenario frecuente al hacer `terraform destroy`: Terraform intenta eliminar un SG pero falla con `DependencyViolation` porque aún hay una ENI usándolo (Lambda en VPC, ECS Fargate task, RDS interface).

```hcl
resource "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.app_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Dar más tiempo para que AWS limpie las ENIs antes de fallar
  timeouts {
    delete = "10m"   # Por defecto son 5 minutos
  }
}
```

El bloque `timeouts { delete = "10m" }` le da a Terraform 10 minutos para reintentar el borrado mientras AWS limpia automáticamente las ENIs de las Lambdas/ECS tasks terminadas. Especialmente útil en pipelines de CI/CD con `terraform destroy` automático.

---

## 4.7 SGs Multi-Cuenta con AWS Organizations

En arquitecturas enterprise con cuentas segregadas (cuenta de Shared Services, cuenta de Producción), puedes referenciar SGs de otras cuentas mediante el formato `ACCOUNT_ID/SG_ID`:

```hcl
resource "aws_security_group_rule" "from_shared" {
  type                     = "ingress"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = "123456789012/sg-0abc1234def"   # SG de otra cuenta
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
}
```

Requisitos: VPC Peering activo entre cuentas, AWS RAM (Resource Access Manager) configurado y misma región. Útil cuando la cuenta de Shared Services tiene un SG de "herramienta de seguridad" que necesita acceso a todos los recursos de Producción.

---

## 4.8 NACLs: El Firewall Stateless de la Subred

Mientras los Security Groups protegen recursos individuales, las **Network ACLs (NACLs)** operan a nivel de **subred completa**. La diferencia fundamental:

| Característica | Security Group | NACL |
|----------------|---------------|------|
| Nivel | Instancia/ENI | Subred |
| Estado | **Stateful** (respuestas automáticas) | **Stateless** (debes definir ingress Y egress) |
| Reglas | Solo Allow | Allow Y Deny |
| Evaluación | Todas las reglas se evalúan | Primera coincidencia gana |
| Uso principal | Control fino por recurso | Bloqueo rápido de IPs maliciosas |

Son **complementarios, no sustitutos**. La defensa en profundidad requiere ambos.

---

## 4.9 NACLs: Números de Regla y Puertos Efímeros

Las NACLs son stateless: si permites entrada en el puerto 443, **debes también permitir explícitamente la salida** en los puertos efímeros (1024-65535) para que las respuestas puedan llegar al cliente.

```
Cliente           →      Puerto 443 (ingress rule 100)     →     Servidor
Cliente           ←      Puerto 52847 (efímero, egress rule 900)   ←     Servidor
```

El orden de las reglas importa. Usa incrementos de 100 para permitir insertar reglas sin renumerar:

```hcl
# Crear la NACL
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id]
  tags       = { Name = "public-nacl" }
}

# Regla 100: Permitir entrada HTTPS
resource "aws_network_acl_rule" "https_in" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false          # false = ingress
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Regla 900: Permitir salida en puertos efímeros (respuestas)
resource "aws_network_acl_rule" "ephemeral_out" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 900
  egress         = true           # true = egress
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}
```

> **Error clásico:** olvidar los puertos efímeros de salida hace que los clientes nunca reciban respuestas — la conexión TCP se establece pero los datos no llegan. Es un error muy difícil de depurar porque el tráfico de entrada parece estar bien.

---

## 4.10 Cuándo Usar NACLs

Las NACLs son ideales en tres escenarios específicos:

1. **Bloquear IPs maliciosas:** añade una regla Deny con número bajo (ej. 50) antes del Allow general. El deny se evalúa primero.
2. **Compliance (PCI-DSS/HIPAA):** los estándares de cumplimiento a veces requieren una segunda capa de filtrado independiente de los SGs.
3. **Defensa en profundidad:** si un Security Group está mal configurado, la NACL actúa como red de seguridad adicional.

Para aplicaciones estándar, con SGs bien configurados es suficiente. Las NACLs añaden complejidad (gestionar puertos efímeros) que solo vale la pena cuando hay un requisito específico.

---

## 4.11 Troubleshooting de Seguridad de Red

| Síntoma | Causa probable | Fix |
|---------|----------------|-----|
| Conexión rechazada en puerto correcto | Regla de SG falta o usa protocolo incorrecto | Verificar `from_port`, `to_port`, `protocol` y `cidr_blocks`/`source_security_group_id` |
| Conexión TCP se establece pero no hay datos | NACL falta regla de egress para puertos efímeros (1024-65535) | Añadir `aws_network_acl_rule` de egress para puertos efímeros |
| `DependencyViolation` al destruir SG | ENIs de Lambda/ECS/RDS aún usan el SG | Añadir `timeouts { delete = "10m" }` o destruir los recursos que usan el SG primero |
| Instancia en subred privada recibe tráfico de Internet | SG tiene `0.0.0.0/0` en ingress y la subred tiene ruta al IGW | Revisar que la subred sea realmente privada (sin ruta al IGW) |

---

## 4.12 Resumen: Los Guardianes del Tráfico

```
Internet
    ↓
NACL (Subred) — Stateless, Allow+Deny, primera regla que coincide
    ↓
Security Group (Recurso) — Stateful, solo Allow, todas las reglas se evalúan
    ↓
EC2 / RDS / Lambda
```

| Recurso | Nivel | Estado | Uso |
|---------|-------|--------|-----|
| `aws_security_group` | ENI/recurso | Stateful | Firewall por recurso, siempre activo |
| `aws_security_group_rule` | Regla individual | — | Añadir/quitar reglas sin recrear el SG |
| `aws_network_acl` | Subred completa | Stateless | Segunda capa, bloqueo de IPs, compliance |
| `aws_network_acl_rule` | Regla NACL | — | Ingress Y egress (recordar efímeros) |

> **Principio de Defensa en Profundidad:** Los SGs son la primera línea de defensa. Las NACLs son la segunda. Úsalos juntos cuando tengas requisitos de compliance, IPs que bloquear o necesites una red de seguridad adicional. Para el 80% de las aplicaciones, SGs bien diseñados son suficientes.

---

> **Siguiente:** [Sección 5 — Interconectividad de VPCs →](./05_interconectividad.md)
