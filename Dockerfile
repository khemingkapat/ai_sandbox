FROM ubuntu:24.04

# Avoid interactive prompt questions during installation
ENV DEBIAN_FRONTEND=noninteractive

# Update system and install SSSD packages
RUN apt-get update && apt-get install -y \
    sssd \
    sssd-ldap \
    libpam-sss \
    libnss-sss \
    && rm -rf /var/lib/apt/lists/*

# Tell Linux identity services (NSS) to use SSSD ('sss')
RUN sed -i 's/^passwd:.*/passwd: files sss/' /etc/nsswitch.conf && \
    sed -i 's/^group:.*/group: files sss/' /etc/nsswitch.conf && \
    sed -i 's/^shadow:.*/shadow: files sss/' /etc/nsswitch.conf

# Copy your local configuration file into the image
COPY sssd.conf /etc/sssd/sssd.conf

# SSSD requires strict 600 permissions on its configuration file to start safely
RUN chmod 600 /etc/sssd/sssd.conf

# Start SSSD daemon in the background and keep the container awake for testing
CMD ["sh", "-c", "sssd --logger=stderr -d 3 && tail -f /dev/null"]
