FROM ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04

RUN groupadd -g 2001 project1 && \
    groupadd -g 2002 project2 && \
    groupadd -g 2003 project3

RUN useradd -m -u 1001 -g 2001 -s /bin/bash user1 && \
    useradd -m -u 1002 -g 2001 -s /bin/bash user2 && \
    useradd -m -u 1003 -g 2002 -s /bin/bash user3 && \
    useradd -m -u 1004 -g 2003 -s /bin/bash user4

RUN usermod -aG project2 user2

# Disable SSSD in supervisor since we use local passwd instead
RUN rm /etc/supervisor/conf.d/sssd.conf
