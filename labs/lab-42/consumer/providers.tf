terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Sin backend — estado local. Este proyecto es solo un consumidor de prueba.
}

provider "aws" {
  region = "us-east-1"
}
