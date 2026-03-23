#!/usr/bin/env bash

set -xeuo pipefail

SCRIPT_DIR="$(dirname "$0")"

SCRIPT="true"
EXTRA_ARGS=()

# Login to docker registry
if [[ -n "$DOCKER_RUN_USERNAME" ]]; then
    echo "$DOCKER_RUN_PASSWORD" | docker login "$DOCKER_RUN_REGISTRY" -u "$DOCKER_RUN_USERNAME" --password-stdin
fi

# Pull the image
docker pull "$DOCKER_RUN_IMAGE"
DOCKER_RUN_IMAGE_ID=$(docker images "$DOCKER_RUN_IMAGE" --format '{{.ID}}')

# Join the specified docker network
if [[ -n "$DOCKER_RUN_DOCKER_NETWORK" ]]; then
    EXTRA_ARGS+=(--network "$DOCKER_RUN_DOCKER_NETWORK")
fi

# Set the entrypoint
if [[ "$DOCKER_RUN_REMOVE_ENTRYPOINT" == "true" ]]; then
    EXTRA_ARGS+=(--entrypoint "")
elif [[ -n "$DOCKER_RUN_ENTRYPOINT" ]]; then
    EXTRA_ARGS+=(--entrypoint "$DOCKER_RUN_ENTRYPOINT")
fi

# Use the specified user
if [[ -n "$DOCKER_RUN_USER" ]] && [[ "$DOCKER_RUN_USER" != "root" ]]; then
    USER_DIR="$RUNNER_TEMP/_home_$DOCKER_RUN_USER"
    GROUP_FILE="$RUNNER_TEMP/_group_$DOCKER_RUN_USER"
    PASSWD_FILE="$RUNNER_TEMP/_passwd_$DOCKER_RUN_USER"

    # Get the original files from the container
    CID="$(docker create "$DOCKER_RUN_IMAGE")"
    docker cp "$CID:/etc/group" "$GROUP_FILE"
    docker cp "$CID:/etc/passwd" "$PASSWD_FILE"
    docker rm -f "$CID"

    # Get UserIDs
    USER_ID="$(id -u)"
    GROUP_ID="$(id -g)"

    # Create Home Dir
    mkdir -p "$USER_DIR"
    chown -R $USER_ID:$GROUP_ID "$USER_DIR"

    # Replace the user in the passwd file
    sed -i "/:$USER_ID:[0-9]\{1,\}:/d" "$PASSWD_FILE"
    echo "$DOCKER_RUN_USER:x:$USER_ID:$GROUP_ID::/home/$DOCKER_RUN_USER:/bin/bash" >> "$PASSWD_FILE"

    # Replace the default user group in the group file
    sed -i "/:$GROUP_ID:$/d" "$GROUP_FILE"
    echo "$DOCKER_RUN_USER:x:$GROUP_ID:" >> "$GROUP_FILE"

    # Add arguments to docker run command
    EXTRA_ARGS+=( \
        --user $USER_ID:$GROUP_ID \
        -e HOME=/home/$DOCKER_RUN_USER \
        -v "$USER_DIR":"/home/$DOCKER_RUN_USER" \
        -v "$GROUP_FILE":"/etc/group" \
        -v "$PASSWD_FILE":"/etc/passwd" \
    )

    # Add the needed groups
    for GROUP in $(id -Gn); do
        GID=$(getent group "$GROUP" | cut -d: -f3)
        EXTRA_ARGS+=(--group-add "$GID")

        if [[ "$GID" != "$GROUP_ID" ]]; then
            if grep -q "^$GROUP:" "$GROUP_FILE"; then
                sed -i "/^$GROUP:/s/\$/,$DOCKER_RUN_USER/" "$GROUP_FILE"
            else 
                echo "$GROUP:x:$GID:$DOCKER_RUN_USER" >> "$GROUP_FILE"
            fi
        fi
    done
fi

# Forward docker credentials
if [[ "$DOCKER_RUN_FORWARD_CREDENTIALS" == "true" ]]; then
    SCRIPT="$SCRIPT; echo \"$DOCKER_RUN_PASSWORD\" | docker login \"$DOCKER_RUN_REGISTRY\" -u \"$DOCKER_RUN_USERNAME\" --password-stdin"
fi

# Setup known hosts
if [[ "$DOCKER_RUN_SETUP_KNOWN_HOSTS" == "true" ]]; then
    SCRIPT="$SCRIPT; mkdir -p ~/.ssh; ssh-keyscan -H github.com >> ~/.ssh/known_hosts"
fi

# Setup access token
if [[ -n "$DOCKER_RUN_TOKEN" ]]; then
    AUTH="$(echo "$DOCKER_RUN_TOKEN" | awk '{$1=$1}1')"
    AUTH="x-access-token:$AUTH"
    AUTH="$(printf "$AUTH" | base64)"

    SCRIPT="$SCRIPT; \
        git config --global http.\"https://github.com\".extraheader \"Authorization: Basic $AUTH\"; \
        git config --global --replace-all url.\"https://github.com/\".insteadOf \"ssh://git@github.com/\"; \
        git config --global --add url.\"https://github.com/\".insteadOf \"git@github.com:\""
fi

# Parse passed keys
if [[ -n "$DOCKER_RUN_SSH_KEYS" ]]; then
    SCRIPT="$SCRIPT; eval \"\$(ssh-agent -s)\""
    while IFS= read -r KEY; do
        if [ ! -z "$KEY" ]; then
            SCRIPT="$SCRIPT; echo \"$KEY\" | base64 -d | ssh-add -"
        fi
    done <<< "$DOCKER_RUN_SSH_KEYS"

    SCRIPT="$SCRIPT; \"$GITHUB_WORKSPACE/.github/actions/docker-run/update-keys\""
fi

# Parse the passed volumes
while IFS= read -r VOLUME; do
    IFS=":" read -ra PARTS <<< "$VOLUME"

    if [ "${#PARTS[@]}" != "2" ]; then
        continue;
    fi

    VOLUME_NAME="$HOSTNAME-$DOCKER_RUN_IMAGE_ID-${PARTS[0]}"
    VOLUME_PATH="${PARTS[1]}"

    if ! docker volume ls --format '{{.Name}}' | grep -q "^${VOLUME_NAME}$"; then
        echo "Create docker volume: $VOLUME_NAME"

        docker volume create "$VOLUME_NAME"
    else
        echo "Reuse existing docker volume: $VOLUME_NAME"
    fi

    EXTRA_ARGS+=(-v "$VOLUME_NAME":"$VOLUME_PATH")
done <<< "$DOCKER_RUN_VOLUMES"

# Set environment variables
for ENV in $(export -p | cut -d ' ' -f3 | cut -d '=' -f1 | grep -vE '^(OLDPWD|PATH|PWD|SHL|HOME|HOSTNAME|INPUT_.*|DOCKER_RUN_.*)$'); do
    EXTRA_ARGS+=(-e "$ENV")
done

# Bring up the container and execute the requested command
if [[ -n "$DOCKER_RUN_RUN" ]]; then
    SCRIPT="$SCRIPT; $DOCKER_RUN_RUN"
fi

exec docker run \
    --rm \
    "${EXTRA_ARGS[@]}" \
    -v "/var/run/docker.sock":"/var/run/docker.sock" \
    -v "$GITHUB_WORKSPACE":"$GITHUB_WORKSPACE" \
    -v "$RUNNER_TEMP":"$RUNNER_TEMP" \
    --workdir "$GITHUB_WORKSPACE" \
    "$DOCKER_RUN_IMAGE" \
        bash -c "$SCRIPT"
