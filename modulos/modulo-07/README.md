# Módulo 7 — Cómputo en AWS con Terraform

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Este módulo cubre todos los servicios de cómputo de AWS gestionados con Terraform: desde instancias EC2 clásicas hasta contenedores con ECS/Fargate y funciones serverless con Lambda y API Gateway.

---

## Contexto

> La red está lista (Módulo 5) y los módulos son reutilizables (Módulo 6). Es el momento de desplegar lo que va dentro de esa red: instancias EC2 con auto-escalado, contenedores ECS Fargate y funciones Lambda. El Módulo 7 añade la capa de cómputo a la arquitectura.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Instancias EC2 y Launch Templates](./01_ec2_launch_templates.md) | `aws_instance`, `data.aws_ami`, IMDSv2, User Data y Launch Templates |
| 2 | [Auto Scaling Groups y Load Balancers](./02_asg_load_balancers.md) | ASG, políticas de escalado, ALB, NLB y Target Groups |
| 3 | [Contenedores: Amazon ECS y Fargate](./03_ecs_fargate.md) | Clusters, Task Definitions, Services y Fargate |
| 4 | [Serverless: Lambda y API Gateway](./04_lambda_api_gateway.md) | Funciones Lambda, capas, API Gateway REST y HTTP |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 27](../../labs/lab27/README.md) | Cimientos de EC2: Despliegue Dinámico y Seguro |
| [Lab 28](../../labs/lab28/README.md) | Escalabilidad y Alta Disponibilidad con Zero Downtime |
| [Lab 29](../../labs/lab29/README.md) | Microservicios con ECS Fargate y Malla de Servicios |
| [Lab 30](../../labs/lab30/README.md) | Procesamiento Asíncrono y Resiliencia de Eventos |
| [Lab 31](../../labs/lab31/README.md) | API Serverless: Lambda, API Gateway v2 y Layers |
| [Lab 32](../../labs/lab32/README.md) | FinOps y Rendimiento: Optimización de Cómputo |

---

## Objetivos de aprendizaje

- Crear instancias EC2 con AMI dinámica, IAM Instance Profile e IMDSv2.
- Configurar Launch Templates versionados y Auto Scaling Groups.
- Desplegar servicios ECS en Fargate con balanceador de carga.
- Implementar funciones Lambda con permisos mínimos y API Gateway.
- Diseñar arquitecturas de cómputo escalables y seguras.

---

---

## ¿Qué sigue?

> El cómputo ya funciona. Esas aplicaciones necesitan guardar datos en algún lugar: archivos en S3, registros en RDS, caché en Redis. El Módulo 8 añade la capa de persistencia, cerrando la arquitectura de tres capas clásica: red → cómputo → datos.

---

*[← Módulo 6](../modulo-06/README.md) | [Módulo 8 →](../modulo-08/README.md)*
