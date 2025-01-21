resource "google_compute_network" "default" {
  name                    = "dify-network"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "default" {
  name          = "dify-subnet"
  ip_cidr_range = "10.0.0.0/16"
  region        = var.region
  network       = google_compute_network.default.self_link
}

resource "google_compute_firewall" "allow_lb_healthcheck" {
  name    = "allow-lb-healthcheck"
  network = google_compute_network.default.self_link

  allow {
    protocol = "tcp"
    ports    = ["22", "80"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

resource "google_compute_instance" "dify_vm" {
  name         = "dify-vm"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["dify-vm"]

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
      size  = var.boot_disk_size_gb
    }
  }

  network_interface {
    network    = google_compute_network.default.self_link
    subnetwork = google_compute_subnetwork.default.self_link
  }

  metadata = {
    serial-port-enable = "true"
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update -y
    apt-get install -y \
      ca-certificates curl gnupg lsb-release git

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    usermod -aG docker ubuntu

    cd /home/ubuntu
    sudo -u ubuntu git clone --depth 1 #{var.git_repo_url} /home/ubuntu/#{var.app_dir}

    cd /home/ubuntu/#{var.app_dir}/#{var.docker_compose_dir}
    cp .env.example .env
    sudo -u ubuntu docker compose up -d
  EOT

  labels = {
    app = "dify-docker"
  }
}

resource "google_compute_instance_group" "dify_group" {
  name    = "dify-instance-group"
  zone    = var.zone
  network = google_compute_network.default.self_link

  instances = [
    google_compute_instance.dify_vm.self_link
  ]

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_router" "default" {
  name    = "default-router"
  network = google_compute_network.default.self_link
  region  = var.region
}

resource "google_compute_router_nat" "default" {
  name   = "default-nat"
  router = google_compute_router.default.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_health_check" "dify_healthcheck" {
  name                = "dify-healthcheck"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/apps"
  }
}

resource "google_compute_backend_service" "dify_backend" {
  name          = "dify-backend-service"
  protocol      = "HTTP"
  health_checks = [google_compute_health_check.dify_healthcheck.id]
  timeout_sec   = 30

  backend {
    group = google_compute_instance_group.dify_group.self_link
  }
}

resource "google_compute_url_map" "dify_url_map" {
  name            = "dify-url-map"
  default_service = google_compute_backend_service.dify_backend.self_link
}

resource "google_compute_managed_ssl_certificate" "dify_ssl_cert" {
  name = "dify-ssl-cert"

  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_target_https_proxy" "dify_https_proxy" {
  name             = "dify-https-proxy"
  url_map          = google_compute_url_map.dify_url_map.self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.dify_ssl_cert.self_link]
}

resource "google_compute_global_forwarding_rule" "dify_forwarding_rule" {
  name        = "dify-global-forwarding-rule"
  target      = google_compute_target_https_proxy.dify_https_proxy.self_link
  port_range  = "443"
  ip_protocol = "TCP"
}

resource "google_iap_web_backend_service_iam_member" "dify_iam" {
  project             = var.project_id
  member              = var.allowed_iap_member
  role                = "roles/iap.httpsResourceAccessor"
  web_backend_service = google_compute_backend_service.dify_backend.name
}
