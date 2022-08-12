terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "eu-central-1"
}

# Load availability zones for the region
data "aws_availability_zones" "available" {}

# Create a VPC
resource "aws_vpc" "main" {
  # the cidr block that will be used for the VPC 
  cidr_block = "10.0.0.0/16"
}

# define private subnets, they don't get a public IP
resource "aws_subnet" "private" {
  count             = var.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.main.id
}

# define public subnets, they don't get a public IP
resource "aws_subnet" "public" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id
  map_public_ip_on_launch = true
}

# IGW for the public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# route for public subnets so they have internet
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.main.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  # route everything over the NAT-Instance
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.network_interface.id
  }

}

# connect private subnet with the route-table
resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}


# EC2 NAT Instace Security Group
resource "aws_security_group" "security_group" {
  name        = "nat-${terraform.workspace}"
  description = "Security group for NAT instance"
  vpc_id      = aws_vpc.main.id

  # only allow ingress from our nat-instance, so the host cannot be reached from the outside
  ingress = [
    {
      description      = "Ingress CIDR"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = [aws_vpc.main.cidr_block]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = true
    }
  ]

  # allow egress to anywhere, so the ec2-instance can talk with anything
  egress = [
    {
      description      = "Default egress"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = true
    }
  ]

}

# create a network-interface in the availability zone at 0 - so we only deploy one
# NAT-Instance instead of var.az_count 
resource "aws_network_interface" "network_interface" {
  subnet_id = element(aws_subnet.public.*.id, 0)
  # disable source/destination checking - VERY IMPORTANT for NAT
  source_dest_check = false
  security_groups   = [aws_security_group.security_group.id]

}

# NAT Instance
resource "aws_instance" "nat_instance" {

  # This is the AMI for the Debian 11 ARM Image from the workshop
  ami = "ami-0641a12cca82d2bb6"
  # Smallest and cheapest instance in eu-central-1
  instance_type = "t4g.nano"

  # the name of your SSH-Key in EC2
  key_name = "bg"

  # connect network interface here
  network_interface {
    network_interface_id = aws_network_interface.network_interface.id
    device_index         = 0
  }

  # cloud-init script to setup masquerading in EC2
  user_data = <<EOT
#!/bin/bash
sudo /usr/bin/apt update
sudo /usr/bin/apt install ifupdown
sudo /usr/bin/apt install sudo
/bin/echo '#!/bin/bash
/bin/echo 1 > /proc/sys/net/ipv4/ip_forward
/usr/sbin/iptables -t nat -A POSTROUTING -s ${aws_vpc.main.cidr_block} -j MASQUERADE
' | sudo /usr/bin/tee /etc/network/if-pre-up.d/nat-setup
sudo chmod +x /etc/network/if-pre-up.d/nat-setup
sudo /etc/network/if-pre-up.d/nat-setup 
  EOT

}
