# Módulo 5 — Networking en AWS con Terraform

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

La red es el cimiento de toda arquitectura cloud. Este módulo cubre la creación declarativa de VPCs, subredes, gateways, tablas de rutas, security groups, VPN, Direct Connect, DNS con Route 53 y certificados con ACM.

---

## Contexto

> La seguridad y la identidad ya están en su lugar. Antes de desplegar servidores o bases de datos, los recursos necesitan una red donde vivir. El Módulo 5 construye ese cimiento: VPC, subredes públicas y privadas, gateways de salida, tablas de rutas y security groups, todo calculado dinámicamente con `cidrsubnet`.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [VPC y Subredes](./01_vpc_subredes.md) | `aws_vpc`, `aws_subnet`, `cidrsubnet`, CIDRs secundarios e IPv6 |
| 2 | [Internet Gateway, NAT y VPC Endpoints](./02_gateways_endpoints.md) | IGW, NAT Gateway, NAT Instance y VPC Endpoints |
| 3 | [Enrutamiento](./03_enrutamiento.md) | Route Tables, asociaciones y rutas estáticas/dinámicas |
| 4 | [Security Groups y NACLs](./04_sg_nacl.md) | Reglas de firewall stateful y stateless |
| 5 | [Interconectividad](./05_interconectividad.md) | VPC Peering, Transit Gateway y PrivateLink |
| 6 | [Conectividad Híbrida](./06_conectividad_hibrida.md) | VPN Site-to-Site y Direct Connect |
| 7 | [DNS y Certificados](./07_dns_certificados.md) | Route 53, registros DNS y ACM |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 16](../../labs/lab16/README.md) | Construcción de una Red Multi-AZ Robusta y Dinámica |
| [Lab 17](../../labs/lab17/README.md) | Optimización de Salida a Internet y «NAT Tax» |
| [Lab 18](../../labs/lab18/README.md) | Seguridad y Control de Tráfico en VPC |
| [Lab 19](../../labs/lab19/README.md) | Conectividad Punto a Punto con VPC Peering |
| [Lab 20](../../labs/lab20/README.md) | Hub-and-Spoke con Transit Gateway y RAM |
| [Lab 21](../../labs/lab21/README.md) | Zonas Hospedadas Privadas y Resolución DNS |

---

## Objetivos de aprendizaje

- Diseñar y crear VPCs con subredes públicas y privadas en múltiples AZs.
- Usar `cidrsubnet` y `cidrhost` para calcular direccionamiento automático.
- Configurar Internet Gateway, NAT Gateway y VPC Endpoints.
- Implementar Security Groups con reglas dinámicas usando `for_each`.
- Conectar VPCs con Peering y Transit Gateway.
- Gestionar DNS y certificados TLS con Route 53 y ACM.

---

---

## ¿Qué sigue?

> Tienes red, seguridad y HCL sólido. A estas alturas seguramente has notado que repites el mismo bloque de VPC en múltiples proyectos. El Módulo 6 te da la herramienta para eliminar esa repetición: los módulos de Terraform. Una VPC bien encapsulada, reutilizada en los diez entornos de la empresa.

---

*[← Módulo 4](../modulo-04/README.md) | [Módulo 6 →](../modulo-06/README.md)*
