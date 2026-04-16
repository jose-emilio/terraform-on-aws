# Laboratorio 26 — LocalStack: Gobernanza, Documentación y Publicación

## Qué funciona sin AWS

La mayor parte de este laboratorio **no requiere AWS**:

| Componente | ¿Necesita AWS? | Notas |
|---|---|---|
| terraform-docs | No | Genera docs del código HCL |
| .terraform-docs.yml | No | Configuración local |
| pre-commit hooks | No | terraform_fmt, terraform_validate, terraform_docs |
| Git tags (versionado) | No | Operación local de Git |
| CHANGELOG.md | No | Archivo de texto |

## Qué funciona con LocalStack

Los ejemplos `basic/` y `advanced/` funcionan con LocalStack ya que solo usan S3 (completamente soportado en Community):

```bash
cd labs/lab26/aws/modules/secure-bucket/examples/basic

# Adaptar el provider para LocalStack antes de ejecutar
terraform init
terraform apply
terraform destroy
```

> **Nota:** Para usar LocalStack, necesitas adaptar el bloque `provider "aws"` de cada ejemplo con los endpoints de LocalStack. Consulta los labs anteriores (ej: lab22/localstack) para ver la configuración del proveedor.

## Pipeline local recomendado

Sin ningún proveedor:

```bash
# 1. Formatear
terraform fmt -recursive modules/

# 2. Generar docs
terraform-docs markdown table --output-file README.md --output-mode inject modules/secure-bucket/

# 3. Crear tag
git tag -a v1.0.0 -m "Release v1.0.0"
```
