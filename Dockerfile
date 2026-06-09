FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    libnss-ldapd \
    libpam-ldapd \
    nslcd \
    ldap-utils \
    && rm -rf /var/lib/apt/lists/*

# Configure NSS to use ldap
RUN sed -i 's/^passwd:.*/passwd: files ldap/' /etc/nsswitch.conf && \
    sed -i 's/^group:.*/group: files ldap/' /etc/nsswitch.conf && \
    sed -i 's/^shadow:.*/shadow: files ldap/' /etc/nsswitch.conf

COPY nslcd.conf /etc/nslcd.conf
RUN chmod 640 /etc/nslcd.conf

CMD ["sh", "-c", "nslcd && tail -f /dev/null"]
