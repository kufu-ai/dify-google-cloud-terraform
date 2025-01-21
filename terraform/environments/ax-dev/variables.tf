variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "boot_disk_size_gb" {
  type = number
}

variable "domain_name" {
  type = string
}

variable "allowed_iap_member" {
  type = string
}

variable "git_repo_url" {
  type = string
}

variable "app_dir" {
  type = string
}

variable "docker_compose_dir" {
  type = string
}
