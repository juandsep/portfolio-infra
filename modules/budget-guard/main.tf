# Monthly budget with a hard cap. A budget alone only sends email, so it also
# publishes to Pub/Sub and a function unlinks billing from the project once
# cost reaches the amount. Unlinking stops every paid resource in the project;
# relink the billing account to bring it back.
# ponytail: billing data lags by hours, so spend can pass the amount by a few
# dollars before the cut. Keep the amount below the real limit.

terraform {
  required_providers {
    google  = { source = "hashicorp/google" }
    archive = { source = "hashicorp/archive" }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "billing_account" {
  type = string
}

variable "amount_usd" {
  type = number
}

variable "source_bucket" {
  description = "Bucket in the project that holds the function source."
  type        = string
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "apis" {
  for_each = toset([
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_pubsub_topic" "budget" {
  project    = var.project_id
  name       = "budget-alerts"
  depends_on = [google_project_service.apis]
}

resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account
  display_name    = "${var.project_id} monthly"
  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }
  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.amount_usd)
    }
  }
  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }
  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget.id
    schema_version = "1.0"
  }
  depends_on = [google_project_service.apis]
}

resource "google_service_account" "guard" {
  project      = var.project_id
  account_id   = "billing-guard"
  display_name = "Unlinks billing when the budget is exceeded"
}

# Project Billing Manager can unlink billing from this project only.
# run.invoker lets the Eventarc trigger call the function as this account.
resource "google_project_iam_member" "guard" {
  for_each = toset(["roles/billing.projectManager", "roles/run.invoker"])
  project  = var.project_id
  role     = each.value
  member   = google_service_account.guard.member
}

# Newer projects give the default compute account no roles, so the function
# builds with its own account.
resource "google_service_account" "builder" {
  project      = var.project_id
  account_id   = "billing-guard-builder"
  display_name = "Builds the billing-guard function"
}

# objectViewer is project-wide: the build reads the source from a bucket
# Cloud Functions creates itself (gcf-v2-sources-*), not only source_bucket.
resource "google_project_iam_member" "builder" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.builder.member
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.root}/.terraform/budget-guard.zip"
}

resource "google_storage_bucket_object" "source" {
  name   = "functions/budget-guard-${data.archive_file.source.output_md5}.zip"
  bucket = var.source_bucket
  source = data.archive_file.source.output_path
}

resource "google_cloudfunctions2_function" "guard" {
  project  = var.project_id
  name     = "billing-guard"
  location = var.region

  build_config {
    runtime         = "python312"
    entry_point     = "stop_billing"
    service_account = google_service_account.builder.id
    source {
      storage_source {
        bucket = var.source_bucket
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    available_memory      = "256M"
    service_account_email = google_service_account.guard.email
    environment_variables = {
      PROJECT_ID = var.project_id
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.budget.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.guard.email
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.builder,
  ]
}
