variable "project" {
  type    = string
  default = "lab29-local"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "container_image" {
  type    = string
  default = "nginx:alpine"
}

variable "api_key" {
  type      = string
  sensitive = true
  default   = "mi-clave-de-api-secreta-lab29"
}
