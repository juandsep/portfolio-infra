# portfolio-infra

Shared infrastructure for my portfolio projects on GCP. Each product has its
own GCP project and repository; what they share lives here, in the
`jd-portfolio-shared` project:

- MLflow tracking server on Cloud Run (scales to zero, IAM-only access)
- GCS bucket for MLflow artifacts
- `modules/budget-guard`: a monthly budget that unlinks billing from a
  project once spend reaches it. Product repositories can use it too.

The MLflow database is a Neon Postgres (free tier), outside GCP.

## Setup

Requires `gcloud` and Terraform.

```bash
gcloud auth application-default login
cd terraform
cp terraform.tfvars.example terraform.tfvars   # billing account, clients
terraform init
terraform apply
```

Store the Neon connection string (the value never goes through Terraform).
Use the direct connection, not the pooled one: MLflow runs migrations on
start. `read -s` keeps it out of the screen and the shell history:

```bash
read -rs NEON_URL   # paste the connection string, then Enter
printf '%s' "$NEON_URL" | gcloud secrets versions add mlflow-db-uri --data-file=- --project jd-portfolio-shared
unset NEON_URL
```

Build the MLflow image, then deploy it:

```bash
REPO=$(terraform output -raw image_repository)
gcloud builds submit ../mlflow --tag "$REPO/mlflow:3.16.1-2" --project jd-portfolio-shared
terraform apply -var "mlflow_image=$REPO/mlflow:3.16.1-2"
```

Put `mlflow_image` in `terraform.tfvars` so later applies keep it.

## Using MLflow

Open the UI through an authenticated local proxy:

```bash
gcloud run services proxy mlflow --region us-central1 --project jd-portfolio-shared
# http://localhost:8080
```

From code, send an identity token. It expires after one hour:

```bash
export MLFLOW_TRACKING_URI=$(terraform -chdir=terraform output -raw mlflow_url)
export MLFLOW_TRACKING_TOKEN=$(gcloud auth print-identity-token)
```

To give a product access, add its service accounts to `mlflow_clients`
(log runs and models) or `model_readers` (load models only) and apply.
