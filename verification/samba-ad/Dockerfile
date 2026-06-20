FROM debian:12-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        samba smbclient krb5-config krb5-user winbind ldb-tools \
        dnsutils procps iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53 88 135 389 445 464 636

ENTRYPOINT ["/entrypoint.sh"]
