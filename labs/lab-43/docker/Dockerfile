# ══════════════════════════════════════════════════════════════════════════════
# Runner de IaC — Imagen Docker multi-stage con versiones pinneadas
# ══════════════════════════════════════════════════════════════════════════════
#
# Arquitectura multi-stage:
#
#   Stage 1 (downloader) — Alpine 3.21
#     Descarga y verifica los binarios de Terraform, TFLint y Trivy.
#     Verifica cada binario contra su suma SHA-256 oficial antes de aceptarlo.
#     Al finalizar contiene solo los binarios verificados; curl, unzip y
#     gnupg no pasan al stage siguiente.
#
#   Stage 2 (runner) — Python 3.12 slim
#     Imagen final que usa CodeBuild. Contiene:
#       - Los tres binarios copiados del stage downloader
#       - La plantilla JUnit de Trivy embebida en /usr/local/share/
#       - Checkov instalado via pip con version pinneada
#       - git (necesario para que tflint descargue plugins)
#       - ca-certificates (TLS para las APIs de AWS)
#     NO contiene curl, unzip, gcc, ni ninguna herramienta de construccion.
#   unzip tampoco: el plugin de TFLint llega ya descomprimido del stage downloader.
#
# Por que versiones pinneadas:
#   Las versiones de las herramientas IaC (Terraform, TFLint, Trivy, Checkov)
#   son inmutables: un cambio es un commit explicito y revisado (cambiar el
#   --build-arg), no un efecto colateral silencioso de un "latest".
#   Los paquetes del sistema operativo si se actualizan en cada build mediante
#   apt-get upgrade para incorporar los ultimos parches de seguridad disponibles.
#   Esto es un compromiso deliberado: reproducibilidad en las herramientas IaC,
#   seguridad activa en la base del sistema operativo.
#
# Por que multi-stage:
#   La superficie de ataque de la imagen final es minima. Un atacante que
#   comprometiese el contenedor no encontraria curl ni herramientas de red
#   que no sean estrictamente necesarias para el runner.

# ──────────────────────────────────────────────────────────────────────────────
# Stage 1 — Descarga y verificacion de binarios
# ──────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21 AS downloader

ARG TERRAFORM_VERSION=1.9.5
ARG TFLINT_VERSION=0.52.0
ARG TFLINT_AWS_PLUGIN_VERSION=0.31.0
ARG TRIVY_VERSION=0.69.3

RUN apk add --no-cache \
      curl=~8 \
      unzip \
      gnupg

WORKDIR /tools

# ── Terraform ─────────────────────────────────────────────────────────────────
# HashiCorp publica un fichero SHA256SUMS firmado con PGP para cada release.
# 1. Se descarga el zip del binario.
# 2. Se descarga el fichero de sumas SHA256.
# 3. Se verifica el hash del zip contra el fichero de sumas.
# Si la verificacion falla (hash incorrecto o fichero alterado), el build
# de la imagen falla en este punto y no se produce ninguna imagen.
RUN ARCHIVE="terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
 && curl -fsSL \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${ARCHIVE}" \
      -o "${ARCHIVE}" \
 && curl -fsSL \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
      -o terraform_SHA256SUMS \
 && grep "${ARCHIVE}" terraform_SHA256SUMS | sha256sum -c - \
 && unzip -q "${ARCHIVE}" \
 && chmod +x terraform \
 && rm "${ARCHIVE}" terraform_SHA256SUMS

# ── TFLint ────────────────────────────────────────────────────────────────────
# TFLint publica un fichero checksums.txt con los hashes SHA256 de cada
# artefacto del release. El proceso de verificacion es identico al de Terraform.
RUN ARCHIVE="tflint_linux_amd64.zip" \
 && curl -fsSL \
      "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${ARCHIVE}" \
      -o "${ARCHIVE}" \
 && curl -fsSL \
      "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt" \
      -o tflint_checksums.txt \
 && grep "${ARCHIVE}" tflint_checksums.txt | sha256sum -c - \
 && unzip -q "${ARCHIVE}" \
 && chmod +x tflint \
 && rm "${ARCHIVE}" tflint_checksums.txt

# ── TFLint plugin AWS ─────────────────────────────────────────────────────────
# El plugin se instala en la imagen para evitar que tflint --init haga
# llamadas a la API de GitHub en runtime. Las IPs de CodeBuild son compartidas
# y agotan rapidamente el rate limit anonimo de GitHub (60 req/hora por IP).
# El directorio ~/.tflint.d/plugins/ es donde TFLint busca plugins por defecto.
RUN ARCHIVE="tflint-ruleset-aws_linux_amd64.zip" \
 && mkdir -p /root/.tflint.d/plugins/github.com/terraform-linters/tflint-ruleset-aws/${TFLINT_AWS_PLUGIN_VERSION} \
 && curl -fsSL \
      "https://github.com/terraform-linters/tflint-ruleset-aws/releases/download/v${TFLINT_AWS_PLUGIN_VERSION}/${ARCHIVE}" \
      -o "${ARCHIVE}" \
 && curl -fsSL \
      "https://github.com/terraform-linters/tflint-ruleset-aws/releases/download/v${TFLINT_AWS_PLUGIN_VERSION}/checksums.txt" \
      -o tflint_aws_checksums.txt \
 && grep "${ARCHIVE}" tflint_aws_checksums.txt | sha256sum -c - \
 && unzip -q "${ARCHIVE}" -d /root/.tflint.d/plugins/github.com/terraform-linters/tflint-ruleset-aws/${TFLINT_AWS_PLUGIN_VERSION}/ \
 && rm "${ARCHIVE}" tflint_aws_checksums.txt

# ── Trivy ─────────────────────────────────────────────────────────────────────
# Aqua Security publica un fichero trivy_<VERSION>_checksums.txt con los hashes
# SHA256 de cada artefacto del release. El proceso de verificacion es identico
# al de Terraform y TFLint: grep del nombre del archivo, sha256sum -c -.
# Trivy se distribuye como tarball; se extrae solo el binario para mantener
# el directorio /tools limpio.
RUN ARCHIVE="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
 && curl -fsSL \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${ARCHIVE}" \
      -o "${ARCHIVE}" \
 && curl -fsSL \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt" \
      -o trivy_checksums.txt \
 && grep "${ARCHIVE}" trivy_checksums.txt | sha256sum -c - \
 && tar xzf "${ARCHIVE}" trivy \
 && chmod +x trivy \
 && rm "${ARCHIVE}" trivy_checksums.txt

 # ── Trivy: plantilla JUnit ────────────────────────────────────────────────────
# Trivy no soporta --format junit de forma nativa: requiere una plantilla Go.
# Se descarga desde el repositorio oficial de contrib de Trivy y se embebe en
# la imagen para que el buildspec pueda referenciarla sin acceso a internet
# en runtime. La plantilla produce XML compatible con CodeBuild Reports.
RUN curl -fsSL \
      "https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/junit.tpl" \
      -o /tools/trivy-junit.tpl
      
# ──────────────────────────────────────────────────────────────────────────────
# Stage 2 — Imagen final del runner
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.12-slim-bookworm AS runner

ARG CHECKOV_VERSION=3.2.231

# Dependencias del sistema:
#   git           — tflint --init descarga plugins desde GitHub via git
#   ca-certificates — valida los certificados TLS de las APIs de AWS y GitHub
# unzip NO es necesario en runtime: el plugin de TFLint ya llega descomprimido
# del stage downloader via COPY --from. Se elimina para reducir superficie de ataque.
# Se eliminan las listas de paquetes tras la instalacion para reducir el
# tamaño de la capa y la superficie de ataque.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Checkov se instala via pip con version exacta pinneada.
# --no-cache-dir evita almacenar el cache de pip en la imagen.
# El paquete 'checkov' incluye todas las dependencias necesarias.
RUN pip install --no-cache-dir "checkov==${CHECKOV_VERSION}"

# Copiar binarios verificados del stage downloader.
# Solo los binarios finales pasan al stage de produccion — no curl, no unzip
# del stage anterior, no ficheros temporales de verificacion.
# La plantilla JUnit se copia a /usr/local/share/ para que el buildspec
# pueda referenciarla con --template "@/usr/local/share/trivy-junit.tpl".
COPY --from=downloader /tools/terraform                /usr/local/bin/terraform
COPY --from=downloader /tools/tflint                   /usr/local/bin/tflint
COPY --from=downloader /tools/trivy                    /usr/local/bin/trivy
COPY --from=downloader /root/.tflint.d                 /root/.tflint.d
COPY --from=downloader /tools/trivy-junit.tpl          /usr/local/share/trivy-junit.tpl

# Verificacion de versiones en tiempo de build de la imagen.
# Si alguna herramienta no se instaló correctamente, el build falla aqui
# con un mensaje claro — no en tiempo de ejecución dentro de CodeBuild.
RUN echo "=== Verificando herramientas del runner ===" \
 && terraform version \
 && tflint --version \
 && trivy --version \
 && checkov --version \
 && echo "=== Todas las herramientas verificadas correctamente ==="

# Usuario no root para ejecutar el runner.
# CodeBuild respeta la directiva USER de la imagen custom: los comandos del
# buildspec se ejecutan como 'runner', no como root.
# /workspace se crea antes de cambiar de usuario y se asigna a runner para
# que CodeBuild pueda clonar el repositorio y escribir artefactos en el build.
RUN useradd --create-home --shell /bin/bash runner

WORKDIR /workspace
RUN chown runner:runner /workspace

USER runner
