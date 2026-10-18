output "instance_id" {
  description = "EC2 instance ID — Ansible connects to this over SSM"
  value       = aws_instance.mattermost.id
}

output "public_ip" {
  description = "Public IP — open http://<public_ip> in a browser"
  value       = aws_instance.mattermost.public_ip
}

output "public_dns" {
  value = aws_instance.mattermost.public_dns
}

output "ami_id" {
  description = "Resolved Ubuntu 24.04 AMI used"
  value       = data.aws_ami.ubuntu.id
}
