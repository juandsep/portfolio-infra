# portfolio-infra

Shared infrastructure for my portfolio projects on GCP. Each product has its
own GCP project and repository; what they share lives here, in the
`jd-portfolio-shared` project:

- MLflow tracking server on Cloud Run (scales to zero, IAM-only access)
- GCS bucket for MLflow artifacts
- `modules/budget-guard`: a monthly budget that unlinks billing from a
  project once spend reaches it. Product repositories can use it too.

The MLflow database is a Neon Postgres (free tier), outside GCP.

Outside the cloud, `grafana/` runs one local Grafana for every project
(see [Grafana](#grafana)).

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

## Grafana

One local Grafana shows every project's dashboards, each in its own folder.
It only reads: metrics and alerts stay in each project's cloud and keep working
while it is stopped, and it costs nothing. The dashboards stay in their own
repositories (`monitoring/grafana/dashboards/`) and are mounted read-only from
the sibling checkouts, so editing one there is enough.

| Folder | Datasource | Credentials |
|---|---|---|
| `document-rag-assistant` | CloudWatch (`us-east-1`) | your AWS profile, from `~/.aws` mounted read-only |
| `botjonh` | Google Cloud Monitoring (`jd-botjonh`) | read-only key from botjonh's `monitoring/grafana-key.sh` |
| `uplift-modeling-pipeline` | Prometheus on `localhost:9090` | none; only up while uplift's monitoring lab runs |

The repositories must sit next to this one (`../botjonh`,
`../uplift-modeling-pipeline`, `../document-rag-assistant`); set
`PORTFOLIO_DIR` if they live elsewhere.

```bash
aws sso login --profile <profile>        # if the profile uses SSO
AWS_PROFILE=<profile> docker compose -f grafana/docker-compose.yml up -d
open http://localhost:3000
docker compose -f grafana/docker-compose.yml down
```

Grafana takes port 3000, so start uplift's lab without its own Grafana:
`docker compose -f monitoring/docker-compose.yml up -d api pushgateway prometheus`.

To add a project: mount its dashboards folder in `grafana/docker-compose.yml`,
add a provider in `grafana/provisioning/dashboards/dashboards.yml`, and a
datasource whose `uid` matches the one its dashboards reference.
