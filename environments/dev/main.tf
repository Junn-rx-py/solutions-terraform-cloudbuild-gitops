terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# Cloud SQL for PostgreSQL (app-db)
# ------------------------------------------------------------------------------
resource "google_sql_database_instance" "app_db" {
  name             = "app-db"
  database_version = "POSTGRES_15"
  region           = var.region
  project          = var.project_id
  
  settings {
    tier = "db-f1-micro" # Small tier for dev
  }
  
  deletion_protection = false
}

resource "google_sql_database" "app_db_name" {
  name     = "app_database"
  instance = google_sql_database_instance.app_db.name
  project  = var.project_id
}

# ------------------------------------------------------------------------------
# Secret Manager (db-secret)
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "db_secret" {
  secret_id = "db-secret"
  project   = var.project_id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_secret_version" {
  secret      = google_secret_manager_secret.db_secret.id
  secret_data = "replace-with-real-password-later"
}

resource "google_sql_user" "app_db_user" {
  name     = "app_user"
  instance = google_sql_database_instance.app_db.name
  project  = var.project_id
  password = google_secret_manager_secret_version.db_secret_version.secret_data
}

# Allow the default compute service account to access secrets (used by Cloud Run)
data "google_compute_default_service_account" "default" {
  project = var.project_id
}

resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  secret_id = google_secret_manager_secret.db_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

# ------------------------------------------------------------------------------
# Cloud Storage (pdf-storage)
# ------------------------------------------------------------------------------
resource "google_storage_bucket" "pdf_storage" {
  name          = "${var.project_id}-pdf-storage" # Must be globally unique
  location      = var.region
  project       = var.project_id
  force_destroy = true
}

# ------------------------------------------------------------------------------
# Pub/Sub Topic (pdf-processing-queue)
# ------------------------------------------------------------------------------
resource "google_pubsub_topic" "pdf_processing_queue" {
  name    = "pdf-processing-queue"
  project = var.project_id
}

# ------------------------------------------------------------------------------
# Cloud Run Services
# ------------------------------------------------------------------------------
locals {
  cloud_run_services = [
    "extension-api",
    "pdf-analysis-service",
    "management-webapp"
  ]
}

resource "google_cloud_run_v2_service" "services" {
  for_each = toset(local.cloud_run_services)

  name     = each.key
  location = var.region
  project  = var.project_id

  template {
    containers {
      image = "gcr.io/${var.project_id}/${each.key}:latest"
      
      env {
        name  = "DB_USER"
        value = google_sql_user.app_db_user.name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app_db_name.name
      }
      env {
        name  = "DB_SOCKET_PATH"
        value = "/cloudsql/${google_sql_database_instance.app_db.connection_name}"
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_secret.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
    
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.app_db.connection_name]
      }
    }
  }
  
  depends_on = [google_secret_manager_secret_iam_member.secret_accessor]
}

# Allow unauthenticated invocations (adjust based on your security needs)
resource "google_cloud_run_service_iam_member" "public_access" {
  for_each = toset(local.cloud_run_services)
  
  location = google_cloud_run_v2_service.services[each.key].location
  project  = google_cloud_run_v2_service.services[each.key].project
  service  = google_cloud_run_v2_service.services[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------------------------
# Regional Load Balancer (management-lb-frontend & management-lb-backend)
# ------------------------------------------------------------------------------
resource "google_compute_region_network_endpoint_group" "management_neg" {
  name                  = "management-webapp-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  project               = var.project_id
  cloud_run {
    service = google_cloud_run_v2_service.services["management-webapp"].name
  }
}

resource "google_compute_region_backend_service" "management_lb_backend" {
  name                  = "management-lb-backend"
  region                = var.region
  project               = var.project_id
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  
  backend {
    group = google_compute_region_network_endpoint_group.management_neg.id
  }
}

resource "google_compute_region_url_map" "management_url_map" {
  name            = "management-url-map"
  region          = var.region
  project         = var.project_id
  default_service = google_compute_region_backend_service.management_lb_backend.id
}

resource "google_compute_region_target_http_proxy" "management_proxy" {
  name    = "management-proxy"
  region  = var.region
  project = var.project_id
  url_map = google_compute_region_url_map.management_url_map.id
}

resource "google_compute_forwarding_rule" "management_lb_frontend" {
  name                  = "management-lb-frontend"
  region                = var.region
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.management_proxy.id
  network_tier          = "STANDARD"
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "extension_api_url" {
  description = "The HTTPS URL of the Extension API to use in your Chrome Extension"
  value       = google_cloud_run_v2_service.services["extension-api"].uri
}