FROM python:3.12-slim

RUN pip install --no-cache-dir "mlflow==3.16.1" "psycopg2-binary==2.9.*" "google-cloud-storage==3.*" \
 && useradd --create-home mlflow
USER mlflow

# BACKEND_STORE_URI comes from Secret Manager (Neon connection string).
# Clients write artifacts straight to GCS, so the server does not proxy them
# (Cloud Run caps request bodies at 32 MB).
CMD mlflow server --host 0.0.0.0 --port "$PORT" --workers 2 \
    --backend-store-uri "$BACKEND_STORE_URI" \
    --default-artifact-root "$ARTIFACT_ROOT" --no-serve-artifacts \
    --allowed-hosts "$ALLOWED_HOSTS"
