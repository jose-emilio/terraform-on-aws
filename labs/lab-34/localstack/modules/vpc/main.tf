resource "aws_vpc" "main" {
  cidr_block = var.cidr_block
  tags       = merge(var.tags, { Name = "${var.project}-vpc" })
}

resource "aws_subnet" "private" {
  for_each          = var.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = merge(var.tags, { Name = "${var.project}-private-${each.key}" })
}
