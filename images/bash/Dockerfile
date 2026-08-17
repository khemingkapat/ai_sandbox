FROM public.ecr.aws/ubuntu/ubuntu:24.04

# Avoid prompts
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
    libnss-extrausers \
    bash-completion \
    build-essential \
    curl \
    git \
    htop \
    jq \
    less \
    nano \
    sudo \
    ttyd \
    unzip \
    vim \
    wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure nsswitch.conf
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf && \
    sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf

# Ensure mount point for extrausers exists
RUN mkdir -p /var/lib/extrausers

COPY start-bash.sh /usr/local/bin/start-bash.sh
RUN chmod +x /usr/local/bin/start-bash.sh

EXPOSE 8888

ENTRYPOINT ["/usr/local/bin/start-bash.sh"]
