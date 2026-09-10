terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5"
    }
  }
}

variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "compartment_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "region" {
  type    = string
  default = "ap-mumbai-1"
}

variable "instance_count" {
  type        = number
  default     = 1
  description = "Number of compute instances to launch"
}

variable "ocpus" {
  type        = number
  default     = 2
  description = "OCPUs per instance (ensure total ocpus across all instances <= free tier limit)"
}

variable "memory_in_gbs" {
  type        = number
  default     = 12
  description = "RAM in GB per instance (ensure total memory across all instances <= free tier limit)"
}

variable "boot_volume_size_in_gbs" {
  type        = number
  default     = 100
  description = "Boot volume size in GB per instance (total free allowance across tenancy is 200 GB)"
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# -----------------------------------------------------------------------------
# SSH Key Generation & Local File Storage
# -----------------------------------------------------------------------------
resource "tls_private_key" "instance_key" {
  algorithm = "ED25519"
}

resource "local_file" "private_key" {
  content         = tls_private_key.instance_key.private_key_openssh
  filename        = "${path.root}/id_ed25519_opspulse"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.instance_key.public_key_openssh
  filename        = "${path.root}/id_ed25519_opspulse.pub"
  file_permission = "0644"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
resource "oci_core_vcn" "opspulse_vcn" {
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "opspulse-vcn"
  dns_label      = "opspulse"
}

resource "oci_core_internet_gateway" "opspulse_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.opspulse_vcn.id
  display_name   = "opspulse-igw"
  enabled        = true
}

resource "oci_core_route_table" "opspulse_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.opspulse_vcn.id
  display_name   = "opspulse-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.opspulse_igw.id
  }
}

resource "oci_core_security_list" "opspulse_sec_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.opspulse_vcn.id
  display_name   = "opspulse-public-sec-list"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_subnet" "opspulse_subnet" {
  cidr_block        = "10.0.1.0/24"
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.opspulse_vcn.id
  display_name      = "opspulse-public-subnet"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.opspulse_rt.id
  security_list_ids = [oci_core_security_list.opspulse_sec_list.id]
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# -----------------------------------------------------------------------------
# Compute Instances (with count)
# -----------------------------------------------------------------------------
resource "oci_core_instance" "opspulse_node" {
  count = var.instance_count

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  display_name        = "opspulse-arm-node-${count.index + 1}"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.opspulse_subnet.id
    display_name     = "primary-vnic-${count.index + 1}"
    assign_public_ip = true
    hostname_label   = "opspulse-${count.index + 1}"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.instance_key.public_key_openssh
  }

  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}

# -----------------------------------------------------------------------------
# SSH Config & Quick Connect Generation
# -----------------------------------------------------------------------------
resource "local_file" "ssh_config_file" {
  content = join("\n\n", [
    for idx, inst in oci_core_instance.opspulse_node : <<-EOT
Host opspulse-${idx + 1}
  HostName ${inst.public_ip}
  User ubuntu
  IdentityFile ${local_file.private_key.filename}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOT
  ])
  filename        = "${path.root}/ssh_config"
  file_permission = "0600"
}

resource "local_file" "connect_script" {
  content = <<-EOT
#!/usr/bin/env bash
TARGET=$${1:-1}
ssh -F ${local_file.ssh_config_file.filename} "opspulse-$${TARGET}"
EOT
  filename        = "${path.root}/connect.sh"
  file_permission = "0755"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "instance_public_ips" {
  description = "List of public IP addresses for all provisioned instances"
  value       = oci_core_instance.opspulse_node[*].public_ip
}

output "ssh_commands" {
  description = "SSH direct commands"
  value       = [for inst in oci_core_instance.opspulse_node : "ssh -i ${local_file.private_key.filename} ubuntu@${inst.public_ip}"]
}

output "quick_connect_example" {
  description = "Usage example for the connect script"
  value       = "./connect.sh 1"
}
