# Laboratorio 25 — LocalStack: Framework de Pruebas

## Tests unitarios (sin AWS ni LocalStack)

Los tests unitarios con `mock_provider` **no necesitan ningún proveedor real**. Funcionan en cualquier máquina con Terraform >= 1.7:

```bash
cd labs/lab25/aws

terraform init -backend=false
terraform test -filter=tests/unit_naming.tftest.hcl
```

Esto ejecuta los tests de nombrado y etiquetado sin conectarse a AWS ni a LocalStack.

## Tests de integración en LocalStack

Los tests de integración (`integration.tftest.hcl`, `idempotency.tftest.hcl`) crean recursos reales. Para ejecutarlos contra LocalStack en lugar de AWS, necesitarías sobreescribir la configuración del proveedor en los archivos de test. Esto **no es posible directamente** porque:

1. `terraform test` usa la configuración del proveedor de `providers.tf`
2. Los archivos `.tftest.hcl` pueden definir un `provider`, pero no pueden configurar endpoints custom de forma práctica para LocalStack

## Alternativas

| Tipo de test | ¿Funciona sin AWS? | Cómo |
|---|---|---|
| Análisis estático (checkov/trivy) | Sí | No necesita proveedor |
| Unit test (mock_provider) | Sí | No necesita proveedor |
| Integration test | No directamente | Requiere AWS o provider override |
| Idempotencia | No directamente | Requiere AWS o provider override |

## Recomendación

Para un pipeline sin coste:
1. `checkov -d modules/` — análisis estático
2. `terraform test -filter=tests/unit_*` — tests unitarios con mock
3. Los tests de integración e idempotencia se ejecutan solo en la cuenta de AWS de sandbox
