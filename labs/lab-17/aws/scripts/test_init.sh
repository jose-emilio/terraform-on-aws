#!/bin/bash
set -euo pipefail

# Instalar SSM Agent (AL2023 minimal no lo incluye)
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
