#!/bin/bash

set -euo pipefail

if [ ! -z "$MINIO_CA_CERT" ]; then
    mkdir -p ~/.mc/certs/CAs/
    echo -e "$MINIO_CA_CERT" > ~/.mc/certs/CAs/ca.crt
fi

mc alias set "$MINIO_ALIAS" "$MINIO_HOST" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"

eval "$MINIO_RUN"
