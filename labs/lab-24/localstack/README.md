# Laboratorio 24 — LocalStack: El "Wrapper" Corporativo: RDS + VPC

![Terraform on AWS](../../../images/lab-banner.svg)


## No disponible en LocalStack Community

Este laboratorio **no tiene versión LocalStack** porque depende de servicios que no están disponibles en la edición Community:

| Servicio | LocalStack Community | Requerido por |
|---|---|---|
| **RDS** | No disponible | Módulo `terraform-aws-modules/rds/aws` |
| **Secrets Manager (RDS managed)** | Parcial | `manage_master_user_password = true` |
| **VPC completa** | Emulación parcial | Módulo `terraform-aws-modules/vpc/aws` (NAT GW, route tables) |

## Alternativa

Para practicar los conceptos de este laboratorio sin coste de AWS:

1. **Composición de módulos y encadenamiento de outputs**: revisa el lab22 (módulos S3) y lab23 (módulos con validación) en sus versiones localstack
2. **Parámetros hardcoded**: el concepto se puede practicar con cualquier módulo que use S3 o VPC básica
3. **`moved {}` blocks**: funciona con cualquier recurso de Terraform, incluso con recursos locales (`local_file`, `null_resource`)

## Ejecución en AWS

Este laboratorio requiere una cuenta de AWS real. Consulta la guía principal en [../README.md](../README.md).

> **Aviso de coste:** La instancia RDS `db.t4g.micro` tiene coste por hora. Destruye los recursos al finalizar.
