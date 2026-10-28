variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used in resource names and tags."
  type        = string
  default     = "startuptech"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the two private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host."
  type        = string
  default     = "t3.micro"
}

variable "backend_instance_type" {
  description = "Instance type for the backend server."
  type        = string
  default     = "t3.micro"
}

variable "mongodb_instance_type" {
  description = "Instance type for the MongoDB server."
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.10/32), allowed to SSH to the bastion. Leave null to auto-detect it at plan time."
  type        = string
  default     = null

  validation {
    condition     = var.my_ip == null || can(cidrhost(var.my_ip, 0))
    error_message = "my_ip must be a CIDR block, e.g. 203.0.113.10/32."
  }
}

variable "public_key_path" {
  description = "Path to the SSH public key uploaded as the EC2 key pair. Only the public key is used, so no private key ends up in state."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
