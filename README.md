# Terraform on AWS

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%3E%3D1.7-7B42BC?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform/docs)
[![AWS](https://img.shields.io/badge/AWS-FF9900?logo=amazonwebservices&logoColor=white)](https://aws.amazon.com)
![Módulos](https://img.shields.io/badge/módulos-12-22863a)
![Laboratorios](https://img.shields.io/badge/laboratorios-51-e36209)

Material oficial del curso **Terraform on AWS** — un recorrido completo desde los fundamentos de la Infraestructura como Código hasta pipelines de CI/CD y prácticas FinOps, usando Terraform como herramienta central sobre AWS.

**Instructor:** José Emilio Vera · Champion AWS Authorized Instructor

---

## Contenido

- [Sobre el curso](#sobre-el-curso)
- [Requisitos previos](#requisitos-previos)
- [Herramientas necesarias](#herramientas-necesarias)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Módulos](#módulos)
- [Laboratorios](#laboratorios)
- [Flujo de trabajo](#flujo-de-trabajo)
- [Recursos](#recursos)

---

## Sobre el curso

El curso cubre el ciclo de vida completo de la infraestructura en AWS gestionada con Terraform: desde el primer `terraform init` hasta pipelines de despliegue continuo, pasando por seguridad, módulos reutilizables, bases de datos, redes y observabilidad.

**12 módulos teóricos · 51 laboratorios prácticos · AWS real + LocalStack**

Cada laboratorio incluye configuración para **AWS real** (`aws/`) y, cuando los servicios lo permiten, configuración para **LocalStack** (`localstack/`) como entorno local sin coste.

---

## Requisitos previos

| Área | Nivel requerido |
|------|----------------|
| Línea de comandos (bash/zsh) | Básico |
| Conceptos cloud (EC2, S3, VPC…) | Básico |
| Git | Básico |
| Experiencia con la consola de AWS | Recomendable |

---

## Herramientas necesarias

- **Terraform** — versión ≥ 1.7 (se recomienda gestionar versiones con `tfenv`)
- **AWS CLI** — configurado con perfiles `default` y `localstack`
- **Docker** y **LocalStack CLI** — para los laboratorios con emulación local
- **Visual Studio Code** con la extensión HashiCorp Terraform
- Cuenta de AWS con permisos de administrador

> Consulta [lab-01](labs/lab-01/README.md) para la guía completa de instalación y configuración del entorno.

---

## Estructura del repositorio

```
terraform-on-aws/
├── modulos/            # 12 módulos teóricos
│   ├── modulo-00/      # Introducción al curso
│   ├── modulo-01/      # Fundamentos de IaC y Terraform
│   ├── modulo-02/      # Lenguaje HCL y configuración avanzada
│   ├── modulo-03/      # Gestión del estado
│   ├── modulo-04/      # Seguridad e IAM con Terraform
│   ├── modulo-05/      # Networking en AWS con Terraform
│   ├── modulo-06/      # Módulos de Terraform
│   ├── modulo-07/      # Cómputo en AWS con Terraform
│   ├── modulo-08/      # Almacenamiento y bases de datos
│   ├── modulo-09/      # Terraform avanzado
│   ├── modulo-10/      # CI/CD y automatización
│   └── modulo-11/      # Observabilidad, tagging y FinOps
└── labs/               # 51 laboratorios prácticos
    ├── lab-00/ … lab-49/
    └── README.md       # Índice completo de laboratorios
```

Cada módulo contiene ficheros de contenido teórico (`01_tema.md`, `02_tema.md`…) y un `README.md` con los objetivos, secciones y enlaces a sus laboratorios.

---

## Módulos

| # | Módulo | Temas principales | Labs |
|---|--------|-------------------|------|
| 0 | [Introducción al curso](modulos/modulo-00/README.md) | Objetivos, agenda, requisitos y metodología | — |
| 1 | [Fundamentos de IaC y Terraform](modulos/modulo-01/README.md) | IaC, ecosistema HashiCorp, instalación, arquitectura interna, LocalStack | lab-00–02 |
| 2 | [Lenguaje HCL y configuración avanzada](modulos/modulo-02/README.md) | Sintaxis HCL, variables, outputs, data sources, expresiones, funciones, meta-argumentos | lab-03–06 |
| 3 | [Gestión del estado](modulos/modulo-03/README.md) | State local y remoto, S3 + DynamoDB, workspaces, terraform_remote_state, recuperación | lab-07–11 |
| 4 | [Seguridad e IAM con Terraform](modulos/modulo-04/README.md) | IAM users/roles/policies, KMS, Secrets Manager, OIDC Federation, Checkov, tfsec | lab-12–15 |
| 5 | [Networking en AWS con Terraform](modulos/modulo-05/README.md) | VPC, subredes, IGW, NAT, endpoints, Security Groups, NACLs, Peering, Transit Gateway, Route 53 | lab-16–21 |
| 6 | [Módulos de Terraform](modulos/modulo-06/README.md) | Diseño, versionado SemVer, Registry público, terraform test, terraform-docs | lab-22–26 |
| 7 | [Cómputo en AWS con Terraform](modulos/modulo-07/README.md) | EC2, Launch Templates, ASG, ALB, ECS Fargate, Lambda, API Gateway | lab-27–32 |
| 8 | [Almacenamiento y bases de datos](modulos/modulo-08/README.md) | S3, EBS, EFS, RDS, Aurora, DynamoDB, ElastiCache | lab-33–36 |
| 9 | [Terraform avanzado](modulos/modulo-09/README.md) | Provisioners, multi-región, drift, import declarativo, refactoring con `moved` | lab-37–40 |
| 10 | [CI/CD y automatización](modulos/modulo-10/README.md) | CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline, GitOps | lab-41–45 |
| 11 | [Observabilidad, tagging y FinOps](modulos/modulo-11/README.md) | CloudWatch, alarmas, dashboards, tagging corporativo, Budgets, Compliance as Code | lab-46–49 |

---

## Laboratorios

El índice completo con descripción de cada laboratorio y conceptos clave está en [labs/README.md](labs/README.md).

### Resumen por módulo

#### Módulo 1 — Fundamentos

| Lab | Título |
|-----|--------|
| [lab-00](labs/lab-00/README.md) | Entorno de Desarrollo Remoto con VSCode en EC2 |
| [lab-01](labs/lab-01/README.md) | Primeros Pasos: Terraform, AWS CLI y LocalStack |
| [lab-02](labs/lab-02/README.md) | Primer despliegue en AWS: bucket S3 con versionado y cifrado |

#### Módulo 2 — Lenguaje HCL

| Lab | Título |
|-----|--------|
| [lab-03](labs/lab-03/README.md) | Variables complejas, `cidrsubnet()` y bloques `dynamic` |
| [lab-04](labs/lab-04/README.md) | `for_each`, data sources y `lifecycle` |
| [lab-05](labs/lab-05/README.md) | `templatefile()`, `file()` y generación de configuraciones |
| [lab-06](labs/lab-06/README.md) | Auditoría con data sources y reportes exportables |

#### Módulo 3 — Gestión del Estado

| Lab | Título |
|-----|--------|
| [lab-07](labs/lab-07/README.md) | Backend remoto con S3, DynamoDB y state locking |
| [lab-07b](labs/lab-07b/README.md) | HCP Terraform como Backend Remoto |
| [lab-08](labs/lab-08/README.md) | Refactorización declarativa: `import`, `moved` y `removed` |
| [lab-09](labs/lab-09/README.md) | Gestión de entornos con workspaces |
| [lab-10](labs/lab-10/README.md) | State splitting: capas de infraestructura independientes |
| [lab-11](labs/lab-11/README.md) | Gestión de Drift y Disaster Recovery |

#### Módulo 4 — Seguridad e IAM

| Lab | Título |
|-----|--------|
| [lab-12](labs/lab-12/README.md) | Gestión de Identidades y Acceso Seguro para EC2 |
| [lab-13](labs/lab-13/README.md) | Cifrado Transversal con KMS y Jerarquía de Llaves |
| [lab-14](labs/lab-14/README.md) | Automatización de Secretos "Zero-Touch" |
| [lab-15](labs/lab-15/README.md) | Blindaje del Pipeline DevSecOps |

#### Módulo 5 — Networking

| Lab | Título |
|-----|--------|
| [lab-16](labs/lab-16/README.md) | Construcción de una Red Multi-AZ Robusta y Dinámica |
| [lab-17](labs/lab-17/README.md) | Optimización de Salida a Internet y "NAT Tax" |
| [lab-18](labs/lab-18/README.md) | Seguridad y Control de Tráfico en VPC |
| [lab-19](labs/lab-19/README.md) | Conectividad Punto a Punto con VPC Peering |
| [lab-20](labs/lab-20/README.md) | Hub-and-Spoke con Transit Gateway y RAM |
| [lab-21](labs/lab-21/README.md) | Zonas Hospedadas Privadas y Resolución DNS |

#### Módulo 6 — Módulos

| Lab | Título |
|-----|--------|
| [lab-22](labs/lab-22/README.md) | Módulos reutilizables: S3 con estándares corporativos |
| [lab-23](labs/lab-23/README.md) | Módulos con validación, precondiciones y postcondiciones |
| [lab-24](labs/lab-24/README.md) | Composición de Módulos Públicos con Estándares Corporativos |
| [lab-25](labs/lab-25/README.md) | Testing de infraestructura con `terraform test` |
| [lab-26](labs/lab-26/README.md) | Gobernanza, Documentación y Publicación "Lean" |

#### Módulo 7 — Cómputo

| Lab | Título |
|-----|--------|
| [lab-27](labs/lab-27/README.md) | Cimientos de EC2: Despliegue Dinámico y Seguro |
| [lab-28](labs/lab-28/README.md) | Escalabilidad y Alta Disponibilidad con Zero Downtime |
| [lab-29](labs/lab-29/README.md) | Microservicios con ECS Fargate y Malla de Servicios |
| [lab-30](labs/lab-30/README.md) | Procesamiento Asíncrono y Resiliencia de Eventos |
| [lab-31](labs/lab-31/README.md) | API Serverless: Lambda, API Gateway v2 y Layers |
| [lab-32](labs/lab-32/README.md) | FinOps y Rendimiento: Optimización de Cómputo |

#### Módulo 8 — Almacenamiento y Bases de Datos

| Lab | Título |
|-----|--------|
| [lab-33](labs/lab-33/README.md) | El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida |
| [lab-34](labs/lab-34/README.md) | Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido |
| [lab-35](labs/lab-35/README.md) | Base de Datos Relacional Crítica: RDS Multi-AZ y Replicación |
| [lab-36](labs/lab-36/README.md) | Arquitectura Moderna NoSQL: DynamoDB con Caché y Eventos |

#### Módulo 9 — Terraform Avanzado

| Lab | Título |
|-----|--------|
| [lab-37](labs/lab-37/README.md) | Orquestación Imperativa con `terraform_data` |
| [lab-38](labs/lab-38/README.md) | Ingeniería de Datos y Resiliencia con Lifecycle |
| [lab-39](labs/lab-39/README.md) | Despliegue Global y Adopción de Infraestructura Existente |
| [lab-40](labs/lab-40/README.md) | Refactorización y Optimización de Performance |

#### Módulo 10 — CI/CD y Automatización

| Lab | Título |
|-----|--------|
| [lab-41](labs/lab-41/README.md) | Gobernanza y Control de Versiones en CodeCommit |
| [lab-42](labs/lab-42/README.md) | Repositorio Privado de Módulos Terraform con CodeArtifact |
| [lab-43](labs/lab-43/README.md) | Canalización CI de IaC con CodeBuild y ECR |
| [lab-44](labs/lab-44/README.md) | Entrega Continua con CodeDeploy |
| [lab-45](labs/lab-45/README.md) | Pipeline GitOps de Terraform con CodePipeline |

#### Módulo 11 — Observabilidad, Tagging y FinOps

| Lab | Título |
|-----|--------|
| [lab-46](labs/lab-46/README.md) | Observabilidad Proactiva y Dashboards as Code |
| [lab-47](labs/lab-47/README.md) | Centralización de Telemetría y Pipeline de Auditoría |
| [lab-48](labs/lab-48/README.md) | Fundamentos FinOps: Tags, Budgets y Spot Instances |
| [lab-49](labs/lab-49/README.md) | Compliance as Code y Remediación Automática |

---

## Flujo de trabajo

```bash
# Iniciar LocalStack (laboratorios con emulación local)
localstack start -d

# Desde el directorio del laboratorio (aws/ o localstack/)
terraform fmt
terraform init
terraform plan
terraform apply

# Al terminar, destruir los recursos para evitar costes
terraform destroy
```

**Buenas prácticas:**

- Añade `terraform.tfstate`, `*.tfstate.backup` y `.terraform/` al `.gitignore`
- Ejecuta `terraform fmt` antes de cada commit
- Revisa siempre la salida de `terraform plan` antes de aplicar en AWS real
- Destruye los recursos al finalizar cada laboratorio

---

## Recursos

- [Documentación oficial de Terraform](https://developer.hashicorp.com/terraform/docs)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Documentación de LocalStack](https://docs.localstack.cloud/)
- [AWS CLI Reference](https://docs.aws.amazon.com/cli/latest/reference/)
- [Terraform Registry — Módulos AWS](https://registry.terraform.io/namespaces/terraform-aws-modules)
