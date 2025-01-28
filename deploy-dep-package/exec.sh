#!/bin/bash

set -e

SCRIPT_DIR="$(dirname $0)"
INCOMING_DIR="$DEPLOY_DEB_PACKAGE_DIR/incoming-$(printf '%05d%05d' $RANDOM $RANDOM)"

ssh -o BatchMode=yes "$DEPLOY_DEB_HOST" "rm -rf \"$INCOMING_DIR\" && mkdir -p \"$INCOMING_DIR\""


for PACKAGE in $DEPLOY_DEB_PACKAGES; do
    scp -o BatchMode=yes "$PACKAGE" "$DEPLOY_DEB_HOST:$INCOMING_DIR"
done

ssh -o BatchMode=yes \
    "$DEPLOY_DEB_HOST" \
    "finish() { \
        rm -rf \"$INCOMING_DIR\"; \
     }; \
     \
     trap finish EXIT; \
     \
     cd \"$DEPLOY_DEB_PACKAGE_DIR/repos/$DEPLOY_DEB_REPO\" \
        && reprepro -V includedeb $DEPLOY_DEB_CODENAME \"$INCOMING_DIR/\"*.deb"
