# Módulo 8 — Almacenamiento y Bases de Datos con Terraform

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Este módulo abarca todos los servicios de almacenamiento y persistencia de datos en AWS: desde almacenamiento de objetos con S3 hasta bases de datos relacionales (RDS, Aurora), NoSQL (DynamoDB) y caché (ElastiCache), gestionados con Terraform.

---

## Contexto

> Las aplicaciones del Módulo 7 procesan datos, pero los datos tienen que persistir en algún lugar. El Módulo 8 añade la capa de almacenamiento: objetos en S3, volúmenes de bloque EBS, bases de datos relacionales RDS y NoSQL DynamoDB con caché ElastiCache, todo con cifrado KMS.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Amazon S3](./01_s3.md) | Buckets, versionado, lifecycle, replicación y acceso |
| 2 | [EBS y EFS](./02_ebs_efs.md) | Volúmenes de bloque y sistema de archivos compartido |
| 3 | [Amazon RDS y Aurora](./03_rds_aurora.md) | Instancias RDS, Aurora Serverless y Proxy |
| 4 | [Amazon DynamoDB](./04_dynamodb.md) | Tablas, índices, streams y autoscaling |
| 5 | [Amazon ElastiCache](./05_elasticache.md) | Redis y Memcached para caché y sesiones |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 33](../../labs/lab33/README.md) | El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida |
| [Lab 34](../../labs/lab34/README.md) | Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido |
| [Lab 35](../../labs/lab35/README.md) | Base de Datos Relacional Crítica: RDS Multi-AZ y Replicación |
| [Lab 36](../../labs/lab36/README.md) | Arquitectura Moderna NoSQL: DynamoDB con Caché y Eventos |

---

## Objetivos de aprendizaje

- Crear y configurar buckets S3 con políticas, versionado y lifecycle.
- Aprovisionar instancias RDS y Aurora con alta disponibilidad y cifrado.
- Diseñar tablas DynamoDB con índices secundarios y autoscaling de capacidad.
- Desplegar clústeres ElastiCache Redis con replication groups.
- Aplicar cifrado en reposo con KMS en todos los servicios de datos.

---

---

## ¿Qué sigue?

> Ya gestionas infraestructura compleja: red, seguridad, cómputo y datos. El siguiente paso es afinar la herramienta. El Módulo 9 profundiza en las capacidades avanzadas de Terraform: adoptar infraestructura existente con `import`, refactorizar sin destruir con `moved`, gestionar múltiples cuentas y optimizar `plan/apply` a escala.

---

*[← Módulo 7](../modulo-07/README.md) | [Módulo 9 →](../modulo-09/README.md)*
