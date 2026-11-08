FROM ghcr.io/mlflow/mlflow:v2.16.0

USER root

# Install PostgreSQL driver for MLflow RDBMS backend store
RUN pip install --no-cache-dir psycopg2-binary

EXPOSE 5000
