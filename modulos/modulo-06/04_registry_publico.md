# Sección 4 — Módulos Públicos AWS en el Registry

> [← Sección anterior](./03_fuentes_versionado.md) | [Siguiente →](./05_testing_modulos.md)

---

## 4.1 El Ecosistema Público: Gigantes a Hombros

Construir toda la infraestructura desde cero es reinventar la rueda. El proyecto **`terraform-aws-modules`** es el estándar de facto para infraestructura AWS en Terraform: más de 80 módulos probados, con millones de descargas mensuales y mantenidos activamente por la comunidad.

El ahorro es enorme: en lugar de escribir y mantener 200 líneas de HCL para una VPC completa, usas 20 líneas que invocan el módulo público. El código interno del módulo — la VPC, las subredes, el IGW, las NAT Gateways, las Route Tables, las EIPs — ya está escrito, probado y documentado.

**Dos categorías principales:**

| Categoría | Origen | Badge | Ideal para |
|-----------|--------|-------|-----------|
| **Oficiales** | HashiCorp | Verified | Servicios HashiCorp: Consul, Vault, Nomad |
| **Comunidad** | `terraform-aws-modules` | Community | Infraestructura AWS completa |

URL: `registry.terraform.io` — busca, compara y reutiliza módulos verificados.

---

## 4.2 El Módulo `vpc/aws`: Una VPC Completa en 20 Líneas

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "production"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true   # Regional: un solo NAT para dev/staging
}
```

Esas 20 líneas crean automáticamente ~15 recursos:
- aws_vpc
- aws_subnet (públicas + privadas)
- aws_internet_gateway
- aws_nat_gateway(s) + aws_eip(s)
- aws_route_table (pública + privada)
- aws_route_table_association (por cada subred)
- aws_default_route_table

Escribir esto desde cero tomaría una tarde y tendría bugs. El módulo público tiene miles de usuarios que ya encontraron y reportaron esos bugs.

---

## 4.3 El Módulo `rds/aws`: Base de Datos con Best Practices

```hcl
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier        = "app-production"
  engine            = "postgres"
  engine_version    = "16.1"
  instance_class    = "db.r6g.large"
  allocated_storage = 100

  # Producción: Alta Disponibilidad + Seguridad
  multi_az             = true
  storage_encrypted    = true
  deletion_protection  = true

  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [module.sg.id]
}
```

El módulo gestiona automáticamente todos los componentes dependientes:

| Componente | Qué hace |
|------------|----------|
| **DB Instance** | Motor, clase, storage, backups, ventana de mantenimiento |
| **DB Subnet Group** | Agrupa subredes privadas para alta disponibilidad |
| **Parameter Group** | Configuración del motor (timeouts, encoding) |
| **Option Group** | Features opcionales (audit, TDE, SSL) |

Cifrado habilitado por defecto, Multi-AZ para HA, backups automáticos — los best practices de AWS están baked in.

---

## 4.4 El Módulo `ecs/aws`: Contenedores Fargate sin Servidores

```hcl
module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "5.11.0"

  cluster_name = "my-app-cluster"

  # Fargate como capacity provider (sin gestión de EC2)
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = { weight = 50 }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = { weight = 50 }   # 50% Spot = ahorro masivo
    }
  }

  # Definición del servicio
  services = {
    api = {
      cpu    = 512
      memory = 1024
      container_definitions = {
        app = {
          image = "123456.dkr.ecr.us-east-1.amazonaws.com/api:latest"
        }
      }
    }
  }
}
```

El módulo abstrae Cluster + Service + Task Definition + networking. Solo defines CPU, memoria e imagen Docker. El deployment circuit breaker con rollback automático está disponible como opción — esencial para despliegues resilientes.

---

## 4.5 El Módulo `eks/aws`: Kubernetes Gestionado

El módulo más complejo del ecosistema AWS — gestiona Control Plane, Node Groups, IRSA (IAM Roles for Service Accounts), Add-ons de Kubernetes y toda la integración de networking:

- Control Plane: endpoint público/privado, versión de K8s, cifrado KMS de secrets, CloudWatch logging
- Node Groups: Managed Node Groups, Self-managed con Launch Templates, Fargate Profiles
- IRSA: IAM Roles para Service Accounts de K8s
- Add-ons: CoreDNS, kube-proxy, vpc-cni, EBS CSI Driver

> **Advertencia:** el módulo EKS tiene más de 50 variables. Lee la documentación completamente antes de configurarlo. El patrón Wrapper es especialmente recomendado aquí para abstraer la complejidad para los equipos de desarrollo.

---

## 4.6 Métricas para Evaluar un Módulo Público

No todos los módulos del Registry son iguales. Antes de adoptarlo en producción, evalúa:

| Criterio | Qué buscar |
|----------|-----------|
| **Descargas / Popularidad** | Miles de descargas semanales indican adopción real y confianza |
| **Actividad del repositorio** | Último commit reciente, PRs mergeados activamente, issues atendidos |
| **Versionado semántico** | Usa SemVer correctamente, tiene CHANGELOG claro entre versiones |
| **Documentación completa** | README con ejemplos, inputs/outputs documentados, use cases reales |
| **Tests automatizados** | CI/CD con tests de integración (Terratest, kitchen-terraform) |
| **Badge 'Verified'** | Módulos oficiales de HashiCorp o partners certificados |

---

## 4.7 El Patrón Wrapper para Módulos Públicos

El problema con los módulos públicos directamente: exposición de 150+ variables que los equipos de desarrollo no deberían tocar (cifrado, logging, tags corporativos).

La solución: **wrapper corporativo** que inyecta los estándares y expone solo lo que el equipo necesita configurar:

```hcl
# modules/wrapper-rds/main.tf

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  # ↓ El equipo de desarrollo elige estos parámetros
  identifier     = var.identifier
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  # ↓ FIJOS: estándares corporativos que no son negociables
  storage_encrypted    = true   # Siempre cifrado
  deletion_protection  = true   # Nunca borrado accidental
  backup_retention_period = 7   # Retención mínima de backups
  tags                 = merge(var.tags, local.mandatory_tags)
}
```

**Resultado:** los equipos usan `wrapper-rds` y obtienen velocidad del ecosistema público + garantía de compliance automática. No pueden crear una BD sin cifrado ni sin protección contra borrado accidental.

---

## 4.8 Fork vs. Wrapper: Cuándo Copiar el Código

Esta decisión tiene consecuencias a largo plazo:

| Estrategia | Pros | Contras | Cuándo usar |
|-----------|------|---------|-------------|
| **Wrapper** | Actualizaciones automáticas del upstream, bajo mantenimiento, la comunidad mantiene el core | No puedes cambiar lógica interna | La mayoría de los casos (90%+) |
| **Fork** | Control total, puedes cambiar cualquier cosa | Pierdes actualizaciones upstream, alto coste de mantenimiento | Bug crítico sin fix upstream, cambios profundos en la lógica |

**Regla de decisión:**
1. Intenta usar el módulo público tal cual
2. Si necesitas inyectar estándares → **Wrapper**
3. Si hay un bug crítico sin fix en upstream → Fork temporal + abre PR upstream para que lo arreglen

El Fork debe ser siempre temporal — la meta es volver al módulo público una vez que el fix esté disponible.

---

## 4.9 Seguridad: Auditoría de Módulos Externos

> ⚠️ **Un módulo público ejecuta código con TUS credenciales AWS.**

Un módulo malicioso podría crear recursos de exfiltración de datos, generar instancias de minería, o simplemente hacer cosas inesperadas con tu cuenta. Antes de adoptar cualquier módulo externo:

```bash
# 1. Revisar el código fuente antes de usar
# Busca: provisioners (exec, local-exec), llamadas HTTP externas,
# recursos no documentados, data sources a endpoints externos

# 2. Analizar con herramientas estáticas
$ trivy config ./modules/  # Detecta misconfiguraciones de seguridad
$ checkov -d . --framework terraform   # 1000+ políticas de seguridad

# 3. Pinear la versión (NUNCA 'latest' o sin version)
version = "~> 5.1.0"   # En Registry
# ?ref=v1.2.3           # En Git
```

**Trust but verify:** trata cada módulo externo como código de terceros que merece una auditoría de seguridad antes de darte acceso a tu infraestructura.

---

## 4.10 Migración: `terraform state mv` al Adoptar Módulos

Cuando adoptas un módulo público para recursos que ya existen, Terraform los vería como recursos nuevos (a crear) y el recurso antiguo como a destruir — lo que significaría downtime.

La solución: mover las direcciones en el state antes de aplicar:

```bash
# 1. Ver las direcciones actuales en el state
$ terraform state list
aws_vpc.main
aws_subnet.public[0]
aws_subnet.private[0]

# 2. Mover al namespace del módulo (la dirección interna del módulo público)
$ terraform state mv \
  aws_vpc.main \
  module.vpc.aws_vpc.this[0]

# 3. Verificar que el plan no muestra cambios destructivos
$ terraform plan
# No changes. Your infrastructure matches the configuration.
```

**Alternativa moderna con `moved` block:**

```hcl
moved {
  from = aws_vpc.main
  to   = module.vpc.aws_vpc.this[0]
}
```

> **Versión mínima:** mover recursos entre módulos con `moved` (uso cross-module) requiere **Terraform ≥ 1.4**. Renombrar un recurso dentro del mismo módulo ya era posible desde v1.1.

El bloque `moved` es preferible porque queda documentado en el código y no requiere comandos manuales propensos a errores.

---

## 4.11 Resumen: Estrategia con Módulos Públicos AWS

```
1. Buscar → registry.terraform.io — evalúa popularidad, tests, docs
2. Evaluar → ¿Tiene lo que necesito? ¿Está activo y mantenido?
3. Adoptar → Wrapper corporativo que inyecta estándares
4. Auditar → trivy, checkov, revisión manual antes de producción
5. Versionar → version = "~> X.Y.Z" — nunca sin restricción
6. Migrar → moved {} para recursos existentes sin downtime
```

| Módulo | Lo que abstrae |
|--------|----------------|
| `terraform-aws-modules/vpc/aws` | VPC + Subnets + IGW + NAT + Routes (~15 recursos) |
| `terraform-aws-modules/rds/aws` | RDS Instance + Subnet Group + Parameter Group + Option Group |
| `terraform-aws-modules/ecs/aws` | Cluster + Service + Task Definition + Autoscaling |
| `terraform-aws-modules/eks/aws` | Control Plane + Node Groups + IRSA + Add-ons |

> **Principio:** El ecosistema público de módulos es uno de los activos más valiosos de Terraform. No lo ignores reinventando la rueda, pero tampoco lo uses sin auditoría. El patrón Wrapper es el punto de equilibrio: velocidad del ecosistema público + control de los estándares corporativos.

---

> **Siguiente:** [Sección 5 — Pruebas de Módulos →](./05_testing_modulos.md)
