FROM codercom/code-server:latest

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

# Copy custom entrypoint script
COPY start-codeserver.sh /usr/local/bin/start-codeserver.sh
RUN chmod +x /usr/local/bin/start-codeserver.sh

# Fix permissions for dynamic users
RUN chmod -R 777 /home/coder

EXPOSE 8888

ENTRYPOINT ["/usr/local/bin/start-codeserver.sh"]

