# Configuración del backend de Terraform y versión mínima del provider de AWS
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# El provider lee las credenciales del perfil "default" de ~/.aws/credentials
provider "aws" {
  region = "us-east-1"
}
