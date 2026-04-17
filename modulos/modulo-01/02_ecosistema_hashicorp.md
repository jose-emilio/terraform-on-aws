# Sección 2 — Ecosistema HashiCorp y posicionamiento de Terraform

> [← Sección anterior](./01_introduccion_iac.md) | [← Volver al índice](./README.md) | [Siguiente sección →](./03_instalacion_entorno.md)

---

## 2.1 HashiCorp Suite: Visión General

HashiCorp no es solo Terraform. Es una suite de herramientas diseñadas para cubrir todas las capas del modelo operativo cloud, cada una especializada en una responsabilidad diferente. Entender la suite completa ayuda a comprender el lugar exacto que ocupa Terraform en la cadena.

| Herramienta | Capa | Función |
|------------|------|---------|
| **Terraform** | Provisioning | Base de aprovisionamiento transversal para cualquier nube. Crea y gestiona la infraestructura. |
| **Vault** | Seguridad | Gestión de secretos, cifrado y acceso dinámico a credenciales. Ningún secreto hardcodeado en el código. |
| **Consul** | Networking | Service mesh, descubrimiento de servicios y configuración distribuida. Los microservicios se encuentran entre sí automáticamente. |
| **Nomad** | Orquestación | Despliegue y gestión de aplicaciones y cargas de trabajo. Alternativa a Kubernetes con menor complejidad operativa. |
| **Packer** | Imágenes | Creación automatizada de imágenes de máquinas virtuales (AMIs en AWS). Una imagen construida una vez, desplegada en miles de instancias. |
| **Boundary** | Acceso | Acceso seguro zero-trust a infraestructura sin VPN. Conectividad granular a servidores, bases de datos y servicios internos según identidad. |

> **Cloud Operating Model:** Cada herramienta se especializa en una capa diferente del stack. Juntas forman un modelo operativo cloud completo y coherente. En este curso nos centramos en Terraform, pero es valioso conocer el ecosistema donde vive.

---

## 2.2 Terraform OSS vs. HCP Terraform

Terraform tiene tres niveles de producto con capacidades crecientes. Es importante entender las diferencias para elegir la opción correcta según el contexto del proyecto.

> **Nota de nomenclatura:** En abril de 2024 HashiCorp renombró "Terraform Cloud" a **HCP Terraform** (HashiCorp Cloud Platform Terraform). Es el mismo producto SaaS con el mismo comportamiento; solo cambió el nombre.

| Característica | OSS (CLI) | HCP Terraform (SaaS) |
|---------------|:---------:|:--------------------:|
| **Coste** | Gratuito | Free tier (hasta 500 recursos, usuarios ilimitados) + planes de pago |
| **Colaboración** | Manual (archivos compartidos) | Nativa (workspaces compartidos) |
| **RBAC** | No incluido | Control de acceso granular |
| **Estado** | Local (archivo `.tfstate`) | Remoto y cifrado automático |
| **Ejecución** | Local en tu máquina | Remota en servidores HashiCorp |
| **VCS Integration** | Manual (tú conectas CI/CD) | Nativa (GitHub, GitLab, Bitbucket) |

En este curso trabajamos principalmente con la **versión OSS** (la CLI), que es la base de todo. HCP Terraform añade comodidades organizativas pero no cambia el lenguaje HCL ni los conceptos fundamentales — todo lo que aprendas en OSS es 100% aplicable en HCP Terraform y Enterprise.

---

## 2.3 Terraform Enterprise

Terraform Enterprise es la versión **auto-alojada** para empresas que requieren aislamiento total de sus datos y redes. No depende de la infraestructura SaaS de HashiCorp — todo corre en los propios servidores del cliente.

Está diseñada para corporaciones con requisitos estrictos de seguridad y compliance, como entidades financieras, organismos de salud o instituciones gubernamentales donde los datos no pueden salir del perímetro corporativo.

### Características diferenciadoras de Enterprise

| Funcionalidad | Descripción |
|--------------|-------------|
| **Auditoría Avanzada** | Logs detallados de cada operación con integración a SIEM corporativo. Trazabilidad completa de quién aplicó qué y cuándo. |
| **SSO Corporativo** | Integración con LDAP, SAML y OIDC para autenticación centralizada. Los usuarios se gestionan desde el Active Directory de la empresa. |
| **Soporte 24/7** | SLA empresarial con soporte dedicado y tiempos de respuesta garantizados. Esencial en entornos de producción críticos. |
| **Sectores Regulados** | Ideal para banca, salud y gobierno que no pueden usar nubes públicas compartidas por requisitos normativos (PCI-DSS, HIPAA, ENS). |

---

## 2.4 BSL y OpenTofu

Este es un tema que todo profesional del sector debe conocer: en agosto de 2023, HashiCorp cambió la licencia de Terraform.

### El cambio de licencia: de MPL a BSL

HashiCorp cambió la licencia de Terraform de **Mozilla Public License (MPL)** a **Business Source License (BSL)**. Este cambio restringe el uso comercial competitivo del código fuente — básicamente, no puedes tomar el código de Terraform y vender un producto que compita directamente con HashiCorp.

Sin embargo, es importante aclarar: **el uso de Terraform por parte de empresas para gestionar su propia infraestructura sigue siendo completamente libre y gratuito**. Solo está restringido quien quiera construir un producto comercial que compita con HCP Terraform o Enterprise.

### OpenTofu: la respuesta de la comunidad

La comunidad open source respondió al cambio de licencia creando **OpenTofu**, un fork verdaderamente open source bajo la **Linux Foundation** (la misma fundación que gestiona el kernel de Linux).

OpenTofu mantiene compatibilidad con el lenguaje HCL y los proveedores existentes. En la práctica, es un reemplazo directo de Terraform CLI con las mismas capacidades.

### ¿Qué significa para este curso?

> **El lenguaje HCL sigue siendo el estándar de facto**, independientemente de la herramienta específica (Terraform o OpenTofu). Los conocimientos que adquieras en este curso son **100% transferibles** entre ambas herramientas. Aprende HCL → dominas ambos mundos.

---

## 2.5 Comunidad, Registry y Proveedores

Uno de los factores más importantes del éxito de Terraform es su comunidad y su ecosistema de proveedores.

### Terraform Registry: El Hub Central

El **Terraform Registry** ([registry.terraform.io](https://registry.terraform.io)) es el catálogo oficial donde se encuentran miles de proveedores y módulos listos para usar. Su arquitectura de plugins permite que cualquier empresa cree su propio Provider para automatizar sus servicios — desde AWS hasta Datadog, Cloudflare, GitHub o incluso servicios internos propietarios.

### Dimensiones del ecosistema

| Métrica | Cifra |
|---------|-------|
| Providers disponibles | **+3.500** |
| Módulos publicados | **+12.000** |
| Descargas al mes | **+200 millones** |
| Stars en GitHub | **+40.000** |

### Principales proveedores

| Proveedor | Recursos aproximados |
|-----------|:-------------------:|
| **AWS** | +1.600 resources |
| **Azure** | +900 resources |
| **Google Cloud** | +800 resources |
| **Kubernetes** | +70 resources |

La riqueza de este ecosistema es lo que hace a Terraform una apuesta segura a largo plazo: si existe una API, probablemente ya existe un provider de Terraform para gestionarla.

---

## 2.6 Roadmap y Versiones de Terraform

Entender la evolución de Terraform ayuda a comprender las decisiones de diseño del lenguaje y a evitar patrones obsoletos.

| Versión | Año | Hito |
|---------|-----|------|
| **0.1** | 2014 | Primer release público. Concepto básico de providers y resources. |
| **0.12** | 2019 | **El mayor salto de la historia**: HCL2 con expresiones ricas, `for_each`, bloques `dynamic`, tipos de datos avanzados. Cambió radicalmente la forma de escribir Terraform. |
| **1.0** | 2021 | Estabilidad garantizada del lenguaje. Compromiso de compatibilidad hacia atrás entre versiones menores. |
| **1.5+** | 2023+ | Import declarativo, bloques `check`, `moved`, `removed`. Mejoras continuas en testing y drift detection. |
| **1.9** | 2024 | Mejoras en rendimiento, providers más rápidos, nuevas capacidades de testeo. |
| **1.10** | 2024 | S3 native locking sin DynamoDB (`use_lockfile = true`), ephemeral values y resources, funciones definidas por providers. |
| **1.11** | 2025 | Argumentos `dynamodb_table` y `dynamodb_endpoint` marcados como deprecated. Mejoras en recursos efímeros. |
| **1.12** | 2025 | Mejoras en el framework `terraform test`, soporte CLI para Terraform Stacks (feature de HCP Terraform administrable desde la CLI) y optimizaciones de rendimiento en planes grandes. |
| **1.13** | 2025 | Mejoras en la gestión de providers y en la paralelización de operaciones. Incrementos de estabilidad y parches de seguridad. |
| **1.14** | 2026 | Versión estable actual. Refinamientos en recursos efímeros y mejoras incrementales de rendimiento. |

### La importancia de la versión 1.0

Tras alcanzar la versión 1.0, Terraform garantiza **estabilidad a largo plazo** en su lenguaje HCL. Los cambios entre versiones menores son retrocompatibles, lo que permite actualizar con confianza. Puedes ir de 1.5 a 1.9 sabiendo que tu código seguirá funcionando.

La versión **0.12** fue el hito más significativo: introdujo HCL2 con expresiones dinámicas, `for_each` y bloques `dynamic` que cambiaron radicalmente la forma de escribir código Terraform. Cualquier documentación anterior a 0.12 puede considerarse obsoleta en términos de buenas prácticas.

> **Consejo práctico:** Mantente siempre en versiones recientes para aprovechar mejoras de rendimiento y parches de seguridad. Usa `tfenv` (que veremos en la siguiente sección) para gestionar versiones de forma profesional.

---

## 2.7 El concepto de Provider

El Provider es la pieza técnica fundamental que conecta Terraform con el mundo exterior. Comprender cómo funciona internamente explica por qué Terraform puede gestionar tantos servicios diferentes.

### Arquitectura de Plugins

```
Código HCL → Terraform Core → gRPC → Provider Plugin → API del Servicio Cloud
```

El Provider es el **binario** que traduce el código HCL en llamadas a la API del servicio final. Terraform Core es agnóstico y delega **toda** la lógica de negocio de cada servicio en estos plugins externos. Terraform no sabe nada de cómo crear un bucket S3; eso lo sabe el AWS Provider.

Cada provider se descarga del Registry durante `terraform init` y se ejecuta como un **proceso independiente** que se comunica con el Core vía **gRPC**.

### Comunicación gRPC

gRPC es un protocolo de alto rendimiento desarrollado por Google. Terraform y sus proveedores se comunican mediante gRPC, lo que proporciona tres ventajas clave:

| Ventaja | Descripción |
|---------|-------------|
| **Independencia** | Core y plugins se actualizan por separado. El AWS Provider puede lanzar una nueva versión sin que Terraform Core cambie. |
| **Estabilidad** | Un fallo en un plugin no afecta al Core ni a otros plugins. Si el provider de Kubernetes falla, el de AWS sigue funcionando. |
| **Extensibilidad** | Cualquiera puede crear su propio provider. Solo necesita implementar la interfaz gRPC que Terraform Core espera. |

> **Analogía:** El gRPC es como un traductor universal que permite a Terraform hablar cualquier "idioma" de nube sin cambiar su núcleo.

---

## 2.8 Terraform es la herramienta líder del mercado

Terraform se ha consolidado como la herramienta líder del mercado IaC por tres razones fundamentales:

1. **Versatilidad multi-cloud**: un solo lenguaje para gestionar cualquier servicio con API
2. **Comunidad masiva**: más de 3.500 providers y 12.000 módulos listos para usar
3. **Respaldo empresarial**: HashiCorp (división de IBM desde febrero de 2025), con soporte comercial y roadmap activo

> **Contexto corporativo:** En febrero de 2025, IBM completó la adquisición de HashiCorp por 6.400 millones de dólares. HashiCorp continúa operando como división independiente dentro de IBM, manteniendo el desarrollo activo de Terraform y el resto de sus productos.

El dominio de Terraform es una de las **habilidades más demandadas** en el mercado cloud actual. Aparecer en ofertas de trabajo como "Terraform" junto a "AWS" es hoy tan común como "SQL" junto a "base de datos".

> La siguiente sección será 100% práctica: instalaremos Terraform, AWS CLI, tfenv y todas las herramientas necesarias para empezar a desplegar infraestructura real.

---

> **Siguiente:** [Sección 3 — Instalación y configuración del entorno →](./03_instalacion_entorno.md)
