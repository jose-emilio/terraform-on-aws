# Laboratorio 13 — LocalStack: Cifrado Transversal con KMS y Jerarquía de Llaves

![Terraform on AWS](../../../images/lab-banner.svg)


Entorno local con LocalStack para practicar los recursos KMS y S3 del laboratorio
sin necesidad de una cuenta de AWS.

> Para la guía completa (conceptos, arquitectura, retos y buenas prácticas)
> consulta el [README principal](../README.md).

## Limitaciones respecto a AWS real

| Aspecto | LocalStack Community |
|---------|---------------------|
| CMK (`aws_kms_key`) | Soportada |
| Alias KMS | Soportado |
| Cifrado/descifrado con la CMK | Soportado |
| Key Policy con segregación de roles | Policy simplificada (sin `data.aws_caller_identity`) |
| Rotación automática (`enable_key_rotation`) | Aceptada, no ejecutada realmente |
| S3 con SSE-KMS | Soportado |
| Volumen EBS cifrado | **Omitido** — EBS no está disponible en LocalStack Community |
| Política de bucket con `StringNotEqualsIfExists` | **Omitida** — condición no implementada en LocalStack Community |

## Prerrequisitos

- LocalStack CLI instalado y Docker en ejecución.
- Terraform ≥ 1.5.
- AWS CLI con perfil configurado para LocalStack (`AWS_ENDPOINT_URL`).

## Despliegue

```bash
# Arrancar LocalStack
localstack start -d

cd labs/lab13/localstack
terraform init
terraform plan
terraform apply
```

## Verificación en LocalStack

```bash
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566

# Describir la CMK
aws kms describe-key --key-id alias/lab13-main

# Verificar estado de rotación
aws kms get-key-rotation-status \
  --key-id $(terraform output -raw cmk_key_id)

# Cifrar texto plano con la CMK
# --cli-binary-format raw-in-base64-out: necesario en AWS CLI v2 para texto plano
CIPHER=$(aws kms encrypt \
  --key-id alias/lab13-main \
  --plaintext "hola-lab13" \
  --cli-binary-format raw-in-base64-out \
  --query CiphertextBlob --output text)
echo "Cifrado: $CIPHER"

# Descifrar (round-trip)
# $CIPHER ya es base64 — decrypt no necesita --cli-binary-format
aws kms decrypt \
  --ciphertext-blob "$CIPHER" \
  --query Plaintext --output text | base64 -d

# Verificar configuración SSE del bucket
aws s3api get-bucket-encryption \
  --bucket $(terraform output -raw s3_bucket_name)
```

## Limpieza

```bash
terraform destroy
localstack stop   # opcional
```
