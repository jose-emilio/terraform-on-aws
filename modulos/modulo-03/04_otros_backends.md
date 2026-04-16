# Sección 4 — Otros Backends

> [← Sección anterior](./03_locking.md) | [Siguiente →](./05_comandos_state.md)

---

## 4.1 Más Allá de S3: El Ecosistema de Backends

Terraform no está limitado a AWS. Distintos equipos tienen distintas necesidades: algunos operan en entornos on-premise con HashiCorp Stack completo, otros en Kubernetes, otros necesitan un SaaS gestionado que elimine toda la operativa de backend. Cada ecosistema tiene su backend ideal.

---

## 4.2 HCP Terraform: El Backend Gestionado (SaaS)

HCP Terraform (HashiCorp Cloud Platform Terraform, antes llamado Terraform Cloud) es la solución SaaS de HashiCorp que **elimina la necesidad de gestionar infraestructura de backend** (S3, DynamoDB, KMS). Ofrece historial visual de estados, bloqueo automático, ejecución remota y gobernanza mediante políticas Sentinel.

**Características principales:**

| Feature | Descripción |
|---------|-------------|
| State gestionado y versionado | Historial visual con diff entre versiones |
| Bloqueo automático | Sin configurar DynamoDB ni S3 Locking |
| Ejecución remota (Remote Runs) | `plan`/`apply` en runners de HashiCorp |
| Políticas Sentinel / OPA | Gobernanza y compliance como código |

**Configuración:**

```hcl
# Sustituye al bloque backend tradicional
terraform {
  cloud {
    organization = "mi-organizacion"

    workspaces {
      name = "mi-proyecto-prod"
    }
  }
}

# Autenticación: ejecutar terraform login
$ terraform login
Token for app.terraform.io:
Enter a value: ••••••••••••••••

$ terraform init
Initializing HCP Terraform...
```

> **Ideal para:** Empresas que quieren eliminar la gestión de infraestructura de backend. Equipos que necesitan colaboración, auditoría y control de acceso centralizado. Disponible con free tier para equipos pequeños.

---

## 4.3 Consul: Estado en el Service Mesh

HashiCorp Consul almacena el State como un valor dentro de su árbol KV distribuido. El locking se realiza mediante **Sessions de Consul**, un mecanismo nativo de bloqueo distribuido sin dependencias adicionales.

**Cómo funciona:**

```
1. Almacenamiento: el JSON del State se guarda en una key del KV store
2. Locking con Sessions: Consul Sessions con TTL proveen bloqueo distribuido
3. Consistencia: protocolo Raft garantiza consistencia entre nodos
4. Liberación automática: si el proceso muere, la Session expira y libera el lock
```

```hcl
terraform {
  backend "consul" {
    address = "consul.mi-empresa.local:8500"
    scheme  = "https"
    path    = "terraform/networking/state"
    lock    = true
  }
}

# El State se almacena en el KV store:
# consul kv get terraform/networking/state

# Autenticación con token (variable de entorno):
$ export CONSUL_HTTP_TOKEN="mi-token-acl"
```

> **Ideal para:** Entornos on-premise que ya usan el stack de HashiCorp (Vault, Nomad, Consul). Arquitecturas con service mesh donde Consul ya está desplegado para descubrimiento de servicios.

---

## 4.4 Kubernetes: Estado dentro del Clúster

Terraform almacena su State directamente en la API de Kubernetes como un **Secret codificado en Base64**. El locking se implementa con Leases nativos de K8s, permitiendo que el estado viva junto a las aplicaciones que gestiona.

**Arquitectura:**

| Aspecto | Detalle |
|---------|---------|
| Almacenamiento | Secret `tfstate-{suffix}` en el namespace indicado |
| Formato | JSON del State codificado en Base64 dentro del Secret |
| Locking | Lease de K8s con TTL automático |
| Control de acceso | RBAC de K8s controla quién accede al State |

```hcl
terraform {
  backend "kubernetes" {
    secret_suffix = "state"
    config_path   = "~/.kube/config"
    namespace     = "terraform-system"
  }
}

# Crea el Secret: tfstate-state en el namespace terraform-system

# Verificar el Secret creado:
$ kubectl get secret tfstate-state \
    -n terraform-system -o yaml
```

> **Ideal para:** Equipos K8s-native que operan infraestructura cloud-native y quieren que el State viva junto a sus workloads. Flujos GitOps con ArgoCD o Flux.

---

## 4.5 HTTP: El Backend Universal y Personalizado

El backend HTTP permite enviar el State a cualquier URL REST que implemente `GET` (lectura), `POST` (escritura) y opcionalmente `LOCK`/`UNLOCK`. Es la interfaz de integración genérica para herramientas como **GitLab Managed Terraform State** o APIs internas personalizadas.

**Endpoints REST:**

```
GET    /state    → Leer el State actual
POST   /state    → Escribir el nuevo State
LOCK   /lock     → Adquirir bloqueo (opcional pero recomendado)
UNLOCK /unlock   → Liberar bloqueo (opcional)
```

```hcl
terraform {
  backend "http" {
    # Endpoint principal (GET/POST)
    address        = "https://mi-api.com/state"

    # Endpoints de locking (opcionales)
    lock_address   = "https://mi-api.com/lock"
    unlock_address = "https://mi-api.com/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"

    # Autenticación básica
    username = "admin"
    password = var.http_password
  }
}
```

> **Casos de uso:** GitLab Managed Terraform State, API personalizada de tu empresa, plataformas internas de IaC, cualquier sistema con interfaz REST.

---

## 4.6 Matriz de Decisión: ¿Cuándo Elegir Cada Uno?

La elección del backend depende de tu infraestructura existente, requisitos de compliance y el nivel de complejidad que estés dispuesto a gestionar:

| Backend | Ecosistema | Locking | Complejidad | Coste |
|---------|-----------|---------|-------------|-------|
| S3 + DynamoDB | AWS nativo | DynamoDB | Media | Bajo |
| S3 Native Lock | AWS (v1.10+) | S3 nativo | Baja | Bajo |
| HCP Terraform | SaaS / Equipos | Automático | Mínima | Free/Pago |
| Consul | On-Prem / HashiCorp | Sessions | Alta | Gratis (OSS) |
| Kubernetes | K8s-native / GitOps | Leases | Media | Gratis |
| HTTP | Custom / GitLab | REST API | Variable | Variable |

**Guía rápida de decisión:**

- **App en AWS, equipo pequeño-medio** → S3 + DynamoDB (o S3 Native Lock en v1.10+)
- **Empresa que no quiere gestionar backend** → HCP Terraform
- **On-premise con HashiCorp Stack** → Consul
- **GitOps con ArgoCD/Flux** → Kubernetes
- **GitLab como plataforma** → HTTP (GitLab Managed State)
- **Requisito compliance/auditoría** → HCP Terraform (Sentinel) o S3+KMS

---

> **Siguiente:** [Sección 5 — Comandos del State →](./05_comandos_state.md)
