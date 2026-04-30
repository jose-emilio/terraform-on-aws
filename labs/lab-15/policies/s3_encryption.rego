# Política OPA/Rego: todos los buckets S3 deben tener cifrado SSE-KMS
#
# Uso:
#   conftest test <ficheros>.tf --policy Labs/Lab15/policies/ --parser hcl2 --all-namespaces

package terraform.s3

# Habilita el syntax Rego v1 (if/contains/in/every) en OPA v0.x.
# En OPA v1.0+ es el comportamiento por defecto y este import es opcional,
# pero se mantiene para máxima compatibilidad con versiones anteriores de conftest.
import rego.v1

# ── Regla 1: bucket sin configuración de cifrado ──────────────────────────────
deny contains msg if {
    some bucket_name
    input.resource.aws_s3_bucket[bucket_name]
    not bucket_has_encryption(bucket_name)
    msg := sprintf(
        "FAIL [s3-encryption]: El bucket '%s' no tiene aws_s3_bucket_server_side_encryption_configuration.",
        [bucket_name],
    )
}

# ── Regla 2: algoritmo de cifrado debe ser aws:kms, no AES256 ─────────────────
deny contains msg if {
    some config_name
    config_entries := input.resource.aws_s3_bucket_server_side_encryption_configuration[config_name]
    entry := config_entries[_]
    rule  := entry.rule[_]
    apply := rule.apply_server_side_encryption_by_default[_]
    apply.sse_algorithm != "aws:kms"
    msg := sprintf(
        "FAIL [s3-kms-only]: La configuración '%s' usa '%s' en lugar de 'aws:kms'.",
        [config_name, apply.sse_algorithm],
    )
}

# ── Regla 3: bucket_key_enabled reduce llamadas KMS (advertencia) ─────────────
warn contains msg if {
    some config_name
    config_entries := input.resource.aws_s3_bucket_server_side_encryption_configuration[config_name]
    entry := config_entries[_]
    rule  := entry.rule[_]
    apply := rule.apply_server_side_encryption_by_default[_]
    apply.sse_algorithm == "aws:kms"
    not rule.bucket_key_enabled
    msg := sprintf(
        "WARN [s3-bucket-key]: '%s' no tiene bucket_key_enabled=true (mayor coste en llamadas KMS).",
        [config_name],
    )
}

# ── Helper ────────────────────────────────────────────────────────────────────
# Comprueba si existe alguna config de cifrado asociada al bucket.
# El parser HCL2 convierte aws_s3_bucket.X.id en el string "${aws_s3_bucket.X.id}".
# Se usa contains() para no depender del formato exacto de la interpolación.

bucket_has_encryption(bucket_name) if {
    some config_name
    config_entries := input.resource.aws_s3_bucket_server_side_encryption_configuration[config_name]
    entry := config_entries[_]
    contains(entry.bucket, bucket_name)
}
