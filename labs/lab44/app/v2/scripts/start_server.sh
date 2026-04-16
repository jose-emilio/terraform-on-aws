#!/bin/bash
# AfterInstall: sustituye los placeholders de index.html con los metadatos
# reales de la instancia (IMDSv2) y arranca Apache.
set -euo pipefail

# ── IMDSv2: obtener token ─────────────────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

imds() {
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1"
}

# ── Metadatos ─────────────────────────────────────────────────────────────────
INSTANCE_ID=$(imds instance-id)
INSTANCE_TYPE=$(imds instance-type)
ARCHITECTURE="arm64 (Graviton)"
AZ=$(imds placement/availability-zone)
REGION=$(imds placement/region)
PRIVATE_IP=$(imds local-ipv4)
PRIVATE_HOSTNAME=$(imds local-hostname)
AMI_ID=$(imds ami-id)

ACCOUNT_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/dynamic/instance-identity/document" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['accountId'])")

MAC=$(imds mac)
VPC_ID=$(imds "network/interfaces/macs/${MAC}/vpc-id")
SUBNET_ID=$(imds "network/interfaces/macs/${MAC}/subnet-id")
SG_IDS=$(imds "network/interfaces/macs/${MAC}/security-group-ids" | tr '\n' ' ')
DEPLOY_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Sustituir placeholders en index.html ──────────────────────────────────────
sed -i \
  -e "s|__INSTANCE_ID__|${INSTANCE_ID}|g" \
  -e "s|__INSTANCE_TYPE__|${INSTANCE_TYPE}|g" \
  -e "s|__ARCHITECTURE__|${ARCHITECTURE}|g" \
  -e "s|__AZ__|${AZ}|g" \
  -e "s|__REGION__|${REGION}|g" \
  -e "s|__PRIVATE_IP__|${PRIVATE_IP}|g" \
  -e "s|__PRIVATE_HOSTNAME__|${PRIVATE_HOSTNAME}|g" \
  -e "s|__AMI_ID__|${AMI_ID}|g" \
  -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
  -e "s|__VPC_ID__|${VPC_ID}|g" \
  -e "s|__SUBNET_ID__|${SUBNET_ID}|g" \
  -e "s|__SG_IDS__|${SG_IDS}|g" \
  -e "s|__DEPLOY_TIME__|${DEPLOY_TIME}|g" \
  /var/www/html/index.html

systemctl enable httpd
systemctl start httpd
