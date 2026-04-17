# Módulo 9 — Terraform Avanzado

![Terraform on AWS](../../images/modulo-banner.svg)


> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Este módulo profundiza en las capacidades avanzadas de Terraform: provisioners, expresiones complejas, gestión de providers múltiples, detección de drift, refactoring de infraestructura existente y optimización de rendimiento en despliegues grandes.

---

## Contexto

> Los módulos 1–8 cubrieron el *qué*: qué servicios AWS, qué recursos Terraform, qué patrones de diseño. El Módulo 9 se centra en el *cómo hacerlo mejor*: técnicas avanzadas de HCL, gestión de múltiples providers, detección de drift, refactoring sin downtime y rendimiento en proyectos con cientos de recursos.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Provisioners](./01_provisioners.md) | `file`, `local-exec`, `remote-exec` y cuándo NO usarlos |
| 2 | [Expresiones Avanzadas](./02_expresiones_avanzadas.md) | `templatefile`, `setproduct`, `transpose`, funciones avanzadas |
| 3 | [Providers Múltiples y Alias](./03_providers_avanzados.md) | Multi-cuenta, multi-región, provider inheritance |
| 4 | [Drift y Reconciliación](./04_drift_reconciliacion.md) | Detección de drift, `terraform refresh`, `import` declarativo |
| 5 | [Refactoring con Terraform](./05_refactoring.md) | Bloques `moved`, `removed`, migración de resources a módulos |
| 6 | [Rendimiento y Escala](./06_rendimiento_escala.md) | `-parallelism`, `target`, `-refresh=false`, partial plans |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 37](../../labs/lab-37/README.md) | Orquestación Imperativa con terraform_data |
| [Lab 38](../../labs/lab-38/README.md) | Ingeniería de Datos y Resiliencia con Lifecycle |
| [Lab 39](../../labs/lab-39/README.md) | Despliegue Global y Adopción de Infraestructura Existente |
| [Lab 40](../../labs/lab-40/README.md) | Refactorización y Optimización del Rendimiento |

---

## Objetivos de aprendizaje

- Conocer los provisioners y sus limitaciones como último recurso.
- Dominar expresiones y funciones avanzadas de HCL.
- Gestionar múltiples cuentas y regiones AWS con provider aliases.
- Detectar y reconciliar drift entre el estado y la infraestructura real.
- Refactorizar código Terraform sin downtime usando `moved` y `removed`.
- Optimizar `terraform plan/apply` en proyectos con cientos de recursos.

---

---

## ¿Qué sigue?

> Ya sabes escribir, gestionar y optimizar Terraform manualmente. El problema es que "manualmente" no escala en un equipo: los planes y applies necesitan ocurrir de forma automatizada, revisada y auditable. El Módulo 10 integra Terraform en pipelines CI/CD completos usando los AWS Developer Tools.

---

*[← Módulo 8](../modulo-08/README.md) | [Módulo 10 →](../modulo-10/README.md)*
