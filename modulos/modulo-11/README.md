# Módulo 11 — Observabilidad, Tagging y FinOps

![Terraform on AWS](../../images/modulo-banner.svg)


> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

El módulo final del curso cubre la observabilidad de la infraestructura con CloudWatch, la estrategia de tagging para gobernanza, las prácticas de FinOps para optimización de costes y el concepto de Compliance as Code para auditoría continua.

---

## Contexto

> El pipeline del Módulo 10 despliega infraestructura de forma autónoma. El último paso del ciclo de madurez es observar qué está desplegado, cuánto cuesta y si cumple las políticas. Este módulo cierra el bucle: métricas, alertas, control de costes y auditoría continua.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Amazon CloudWatch](./01_cloudwatch.md) | Métricas, alarmas, dashboards y Composite Alarms |
| 2 | [Logs y Trazas](./02_logs_trazas.md) | CloudWatch Logs, Insights, X-Ray y métricas personalizadas |
| 3 | [Estrategia de Tagging](./03_tagging.md) | Política de tags, tag modules y `default_tags` |
| 4 | [FinOps con AWS](./04_finops.md) | Cost Explorer, Budgets, Savings Plans y rightsizing |
| 5 | [Compliance as Code](./05_compliance_code.md) | AWS Config rules, SCP, Checkov y auditoría automática |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 46](../../labs/lab-46/README.md) | Observabilidad Proactiva y Dashboards as Code |
| [Lab 47](../../labs/lab-47/README.md) | Centralización de Telemetría y Pipeline de Auditoría |
| [Lab 48](../../labs/lab-48/README.md) | Fundamentos FinOps: Tags, Budgets y Spot Instances |
| [Lab 49](../../labs/lab-49/README.md) | Compliance as Code y Remediación Automática |

---

## Objetivos de aprendizaje

- Crear dashboards y alarmas CloudWatch para todos los servicios de la arquitectura.
- Configurar CloudWatch Logs Insights y métricas personalizadas.
- Implementar una estrategia de tagging corporativa con `default_tags`.
- Aplicar prácticas FinOps: presupuestos, savings plans y rightsizing.
- Automatizar la auditoría de compliance con AWS Config y Checkov.

---

---

## Cierre del curso

> Has recorrido el ciclo completo de la infraestructura como código en AWS: desde el primer `terraform init` hasta pipelines de despliegue continuo con gobernanza y FinOps. Cada módulo se apoya en el anterior — la red usa seguridad, el cómputo usa red, los datos usan cómputo, el pipeline automatiza todo, y la observabilidad vigila el conjunto. Ese es el modelo mental de un ingeniero de infraestructura moderno.

---

*[← Módulo 10](../modulo-10/README.md)*
