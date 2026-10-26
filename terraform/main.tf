resource "google_service_account" "recovery" {
  account_id   = "hybridmod-recovery"
  display_name = "HybridMod Recovery VM"
}

resource "google_storage_bucket_iam_member" "backup_reader" {
  bucket = var.backup_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.recovery.email}"
}

resource "google_compute_firewall" "http" {
  name    = "hybridmod-recovery-http"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["hybridmod-recovery"]
}

resource "google_compute_instance" "recovery" {
  name         = "hybridmod-recovery-vm"
  machine_type = "e2-small"
  zone         = var.zone
  tags         = ["hybridmod-recovery"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"

    access_config {}
  }

  service_account {
    email  = google_service_account.recovery.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    project = "HybridMod"
  }

  depends_on = [
    google_storage_bucket_iam_member.backup_reader,
    google_compute_firewall.http
  ]
}

output "recovery_vm_public_ip" {
  description = "Public IP of the HybridMod recovery VM"
  value       = google_compute_instance.recovery.network_interface[0].access_config[0].nat_ip
}
