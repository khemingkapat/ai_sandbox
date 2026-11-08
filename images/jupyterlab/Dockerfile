FROM jupyter/scipy-notebook:latest

USER root

# Install libnss-extrausers
RUN apt-get update && \
    apt-get install -y libnss-extrausers && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure nsswitch.conf
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf && \
    sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf

# Ensure mount point for extrausers exists
RUN mkdir -p /var/lib/extrausers

COPY start-jupyter.sh /usr/local/bin/start-jupyter.sh
RUN chmod +x /usr/local/bin/start-jupyter.sh

# Install MLflow for optional experiment tracking
RUN pip install --no-cache-dir mlflow

# Passive tracking URI pointing to central services
ENV MLFLOW_TRACKING_URI="http://mlflow.services.svc.cluster.local:5000"

# Fix permissions to allow dynamic users to use the default home if needed
# although usually they will use /mnt/storage
RUN chmod -R 777 /home/jovyan

# Removed USER 1000 to allow start-jupyter.sh to run as root and drop privileges

EXPOSE 8888

ENTRYPOINT ["tini", "-g", "--", "/usr/local/bin/start-jupyter.sh"]
