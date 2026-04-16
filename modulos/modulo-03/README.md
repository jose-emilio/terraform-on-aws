# Módulo 3 — Gestión del Estado (State)

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

El State es el activo más crítico de cualquier proyecto Terraform. Este módulo profundiza en su anatomía, backends remotos en AWS (S3 + DynamoDB), bloqueo, comandos de manipulación, workspaces y estrategias avanzadas de gestión.

---

## Contexto

> En el Módulo 2 dominaste el lenguaje HCL. Ahora tus configuraciones despliegan infraestructura real, y aparece la primera pregunta operacional crítica: ¿cómo registra Terraform la diferencia entre lo que describes en código y lo que realmente existe en AWS? La respuesta está en el State.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Fundamentos del State](./01_fundamentos_state.md) | Anatomía, metadata, local vs. remoto y datos sensibles |
| 2 | [Backend remoto en AWS](./02_backend_s3.md) | S3 + cifrado SSE-S3/KMS, versionado, migración y multi-cuenta |
| 3 | [Bloqueo del State](./03_locking.md) | DynamoDB, race conditions y gestión de locks |
| 4 | [Otros backends](./04_otros_backends.md) | HCP Terraform, Azure Blob, GCS y HTTP backend |
| 5 | [Comandos del State](./05_comandos_state.md) | list, show, mv, rm, import, pull, push |
| 6 | [Workspaces y Stacks](./06_workspaces.md) | Workspaces, terraform_remote_state y stacks |
| 7 | [Estrategias avanzadas](./07_estrategias_avanzadas.md) | Segmentación, refactoring y recuperación de estado |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 7](../../labs/lab07/README.md) | Configurar backend S3 con DynamoDB Locking |
| [Lab 7b](../../labs/lab07b/README.md) | HCP Terraform como Backend Remoto *(variante del Lab 7: backend cloud en lugar de S3)* |
| [Lab 8](../../labs/lab08/README.md) | Refactorización Declarativa y Adopción de Infraestructura |
| [Lab 9](../../labs/lab09/README.md) | Gestión de Entornos con Workspaces |
| [Lab 10](../../labs/lab10/README.md) | Arquitectura de State Splitting (Capas de Infraestructura) |
| [Lab 11](../../labs/lab11/README.md) | Gestión de Drift y Disaster Recovery (3-2-1) |

---

## Objetivos de aprendizaje

- Comprender la anatomía completa del archivo `terraform.tfstate`.
- Configurar un backend S3 seguro con cifrado SSE-KMS y versionado.
- Implementar el bloqueo de estado con DynamoDB.
- Usar los comandos `state mv`, `state rm` e `import` con precisión.
- Crear y gestionar workspaces para múltiples entornos.
- Diseñar estrategias de segmentación del state para proyectos grandes.

---

---

## ¿Qué sigue?

> Ya sabes guardar el State de forma segura en S3 con locking DynamoDB. Ese bucket —y toda la infraestructura que lo rodea— requiere permisos IAM, cifrado KMS y políticas de acceso. El Módulo 4 te enseña a construir esa capa de seguridad, y de paso muestra cómo evitar que datos sensibles del State queden expuestos.

---

*[← Módulo 2](../modulo-02/README.md) | [Módulo 4 →](../modulo-04/README.md)*
