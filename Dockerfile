# Set the base image
FROM alpine:3.17

# Install required packages
RUN apk -v --update add \
    python3 \
    py-pip \
    groff \
    less \
    mailcap \
    mysql-client \
    curl \
    py-crcmod \
    bash \
    libc6-compat \
    gnupg \
    coreutils \
    gzip \
    go \
    git \
    pigz \
    zstd && \
    pip3 install --upgrade awscli s3cmd python-magic && \
    rm /var/cache/apk/*

# Set Default Environment Variables
ENV BACKUP_CREATE_DATABASE_STATEMENT=false
ENV TARGET_DATABASE_PORT=3306
ENV CLOUD_SDK_VERSION=367.0.0
ENV COMPRESSION=zstd
ENV COMPRESSION_LEVEL=9
# Release commit for https://github.com/FiloSottile/age/releases/tag/v1.1.1
ENV AGE_VERSION=v1.1.1
ENV BACKUP_PROVIDER=aws

# Install FiloSottile/age (https://github.com/FiloSottile/age)
RUN git clone https://filippo.io/age && \
    cd age && \
    git checkout $AGE_VERSION && \
    go build -o . filippo.io/age/cmd/... && cp age /usr/local/bin/


# Copy backup script and execute
COPY resources/perform-backup.sh /
RUN chmod +x /perform-backup.sh
CMD ["sh", "/perform-backup.sh"]
