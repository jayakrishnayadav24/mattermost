variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "mattermost"
}

variable "instance_type" {
  type    = string
  default = "t3a.medium"
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to SSH on port 22 (break-glass). Lock to your IP in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed to reach Mattermost on port 80"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssm_transfer_bucket" {
  description = "S3 bucket name the aws_ssm Ansible plugin uses to stage files"
  type        = string
}
