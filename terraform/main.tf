provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Latest Ubuntu 24.04 (Noble) AMI from Canonical's official account.
# A data source keeps this idempotent and region-independent (no hardcoded ID).
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Network: VPC + public subnet + internet gateway + route table
# ---------------------------------------------------------------------------
resource "aws_vpc" "mattermost" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.mattermost.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.mattermost.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mattermost.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group: only 22 (SSH break-glass) and 80 (Mattermost via Nginx).
# The pipeline itself deploys over SSM, which needs NO inbound port.
# ---------------------------------------------------------------------------
resource "aws_security_group" "mattermost" {
  name        = "${var.name_prefix}-sg"
  description = "Mattermost host: SSH (22) and HTTP (80) only"
  vpc_id      = aws_vpc.mattermost.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.http_ingress_cidrs
  }

  egress {
    description = "All outbound (SSM agent needs HTTPS to AWS endpoints)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

# ---------------------------------------------------------------------------
# IAM: instance profile granting the SSM managed policy, so Session Manager
# and the aws_ssm Ansible connection plugin reach the host without an SSH key.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "${var.name_prefix}-ec2-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.name_prefix}-ec2-ssm-role" }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The aws_ssm connection plugin stages files through an S3 bucket; allow the
# instance to read/write that single bucket.
resource "aws_iam_role_policy" "ssm_s3_transfer" {
  name = "${var.name_prefix}-ssm-s3-transfer"
  role = aws_iam_role.ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.ssm_transfer_bucket}",
        "arn:aws:s3:::${var.ssm_transfer_bucket}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.name_prefix}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# ---------------------------------------------------------------------------
# EC2 host. No key_name — access is via SSM only.
# ---------------------------------------------------------------------------
resource "aws_instance" "mattermost" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.mattermost.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  # Ubuntu 24.04 ships the SSM agent preinstalled and auto-starting, and the
  # instance profile grants AmazonSSMManagedInstanceCore, so no user_data is
  # needed — the agent registers on its own shortly after boot.

  tags = {
    Name = "${var.name_prefix}-host"
    Role = "mattermost"
  }
}
