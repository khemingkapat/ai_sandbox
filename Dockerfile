FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    sssd \
    sssd-ldap \
    ldap-utils \
    && rm -rf /var/lib/apt/lists/*

# Configure NSS to use sssd
RUN sed -i 's/^passwd:.*/passwd: files sss/' /etc/nsswitch.conf && \
    sed -i 's/^group:.*/group: files sss/' /etc/nsswitch.conf && \
    sed -i 's/^shadow:.*/shadow: files sss/' /etc/nsswitch.conf

COPY sssd.conf /etc/sssd/sssd.conf
RUN chmod 600 /etc/sssd/sssd.conf

CMD ["sssd", "-i", "-d", "3"]
