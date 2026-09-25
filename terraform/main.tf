# Shared project: the MLflow tracking server every product uses, its artifact
# bucket and the project's budget guard. The MLflow database is Neon Postgres,
# outside GCP; its connection string lives in Secret Manager.
# State is local (terraform.tfstate, git-ignored).

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

variable "project_id" {
  type    = string
  default = "jd-portfolio-shared"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "billing_account" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 10
}

variable "mlflow_image" {
  description = "Image built from mlflow/Dockerfile (see README). Empty until the first build."
  type        = string
  default     = ""
}

variable "mlflow_clients" {
  description = "Members that log runs and models (e.g. serviceAccount:x@y.iam.gserviceaccount.com, user:me@gmail.com)."
  type        = list(string)
  default     = []
}

variable "model_readers" {
  description = "Members that only load models, such as serving APIs."
  type        = list(string)
  default     = []
}

provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

data "google_project" "this" {}

resource "google_project_service" "apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-mlflow-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket" "functions" {
  name                        = "${var.project_id}-functions"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.apis]
}

module "budget_guard" {
  source          = "../modules/budget-guard"
  project_id      = var.project_id
  region          = var.region
  billing_account = var.billing_account
  amount_usd      = var.monthly_budget_usd
  source_bucket   = google_storage_bucket.functions.name
}

resource "google_artifact_registry_repository" "images" {
  repository_id = "mlflow"
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
}

# The value is added by hand so it never enters Terraform state:
#   printf '%s' "$NEON_URL" | gcloud secrets versions add mlflow-db-uri --data-file=-
resource "google_secret_manager_secret" "db_uri" {
  secret_id = "mlflow-db-uri"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_service_account" "mlflow" {
  account_id   = "mlflow-server"
  display_name = "MLflow tracking server"
}

resource "google_secret_manager_secret_iam_member" "mlflow_reads_db_uri" {
  secret_id = google_secret_manager_secret.db_uri.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.mlflow.member
}

# The server lists and deletes artifacts from the UI; clients upload directly.
resource "google_storage_bucket_iam_member" "artifacts_writers" {
  for_each = toset(concat(["${google_service_account.mlflow.member}"], var.mlflow_clients))
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "artifacts_readers" {
  for_each = toset(var.model_readers)
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

locals {
  mlflow_host = "mlflow-${data.google_project.this.number}.${var.region}.run.app"
}

resource "google_cloud_run_v2_service" "mlflow" {
  count               = var.mlflow_image == "" ? 0 : 1
  name                = "mlflow"
  location            = var.region
  deletion_protection = false
  # Callers need roles/run.invoker; there is no public access.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.mlflow.email
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
    containers {
      image = var.mlflow_image
      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle = true
      }
      env {
        name  = "ARTIFACT_ROOT"
        value = "gs://${google_storage_bucket.artifacts.name}"
      }
      env {
        name = "ALLOWED_HOSTS"
        # localhost is what `gcloud run services proxy` sends.
        value = "${local.mlflow_host},localhost,localhost:8080"
      }
      env {
        name = "BACKEND_STORE_URI"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_uri.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.mlflow_reads_db_uri]
}

resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = var.mlflow_image == "" ? toset([]) : toset(concat(var.mlflow_clients, var.model_readers))
  name     = google_cloud_run_v2_service.mlflow[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = each.value
}

output "mlflow_url" {
  value = "https://${local.mlflow_host}"
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
