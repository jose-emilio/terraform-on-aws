variable "project" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = map(string)
  description = "Mapa AZ -> ID de subnet privada donde crear los mount targets"
}

variable "ec2_sg_id" {
  type        = string
  description = "ID del Security Group de las instancias EC2"
}

variable "app_uid" {
  type    = number
  default = 1001
}

variable "app_gid" {
  type    = number
  default = 1001
}
