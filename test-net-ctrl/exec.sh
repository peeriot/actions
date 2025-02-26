#!/bin/bash

set -euo pipefail
set -x

TEST_NET_CTRL_COMMAND="${TEST_NET_CTRL_COMMAND:-up}"
TEST_NET_CTRL_NAME="${TEST_NET_CTRL_NAME:-fuu}"
TEST_NET_CTRL_NAMING="${TEST_NET_CTRL_NAMING:-postfix}"
TEST_NET_CTRL_CONFIG_FILE="${TEST_NET_CTRL_CONFIG_FILE:-/work/test-network.yml}"
TEST_NET_CTRL_POLICY_FILE="${TEST_NET_CTRL_POLICY_FILE:-}"
TEST_NET_CTRL_COMPOSE_FILE="${TEST_NET_CTRL_COMPOSE_FILE:-}"
TEST_NET_CTRL_ORCHESTRATOR_NAME="${TEST_NET_CTRL_ORCHESTRATOR_NAME:-}"
TEST_NET_CTRL_ORCHESTRATOR_ADDRESS="${TEST_NET_CTRL_ORCHESTRATOR_ADDRESS:-}"
TEST_NET_CTRL_ORCHESTRATOR_PORT="${TEST_NET_CTRL_ORCHESTRATOR_PORT:-50051}"

POLICY_FILE="${TEST_NET_CTRL_POLICY_FILE:-$TEST_NET_CTRL_CONFIG_FILE}"
COMPOSE_FILE="${TEST_NET_CTRL_COMPOSE_FILE:-$TEST_NET_CTRL_CONFIG_FILE}"
NAME_CACHE_FILE="${RUNNER_TEMP}/test_net_ctrl_name_${TEST_NET_CTRL_NAME}"

panic() {
    echo "Error: $*" >&2 
    exit 1 
}

up() {
    echo "Bring the test network up: $COMPOSE_PROJECT_NAME"

    docker compose -f "$COMPOSE_FILE" up -d
}

down() {
    echo "Shut down the test network: $COMPOSE_PROJECT_NAME"

    docker compose -f "$COMPOSE_FILE" down
}

first_bridge_network_address() {
    CONTAINER="$1"
    NETWORKS="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}} {{"\n"}}{{end}}' "$CONTAINER")"
    
    while read -r NETWORK ADDRESS; do
        DRIVER="$(docker inspect -f '{{.Driver}}' "$NETWORK")"
        if [[ "$DRIVER" == "bridge" ]]; then
            echo "$NETWORK $ADDRESS"
            return
        fi
    done <<< "$NETWORKS"

    panic "Unable to find address of orchestrator: $CONTAINER"
}

update() {
    echo "Update test network policy: $COMPOSE_PROJECT_NAME"

    if [ -z "$TEST_NET_CTRL_ORCHESTRATOR_ADDRESS" ]; then
        if [ -z "$TEST_NET_CTRL_ORCHESTRATOR_NAME" ]; then
            TEST_NET_CTRL_ORCHESTRATOR_NAME="$(docker ps --filter "name=$COMPOSE_PROJECT_NAME-orchestrator" --format '{{.ID}}' | head -n1)"
        fi

        TMP="$(first_bridge_network_address "$TEST_NET_CTRL_ORCHESTRATOR_NAME")"
        read -r NETWORK ADDRESS <<< "$TMP"

        TEST_NET_CTRL_ORCHESTRATOR_ADDRESS="$ADDRESS"

        if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$HOSTNAME" | grep -qw "$NETWORK"; then
            docker network connect "$NETWORK" "$HOSTNAME"
        fi
    fi

    ORCHESTRATOR_ENDPOINT="http://$TEST_NET_CTRL_ORCHESTRATOR_ADDRESS:$TEST_NET_CTRL_ORCHESTRATOR_PORT"

    test-net-admin \
        --orchestrator "$ORCHESTRATOR_ENDPOINT" \
        apply-policies \
            --policies "$POLICY_FILE"
}

mkdir -p "$RUNNER_TEMP"

if [ -f "$NAME_CACHE_FILE" ]; then 
    COMPOSE_PROJECT_NAME=$(<"$NAME_CACHE_FILE")
else 
    case "$TEST_NET_CTRL_NAMING" in
        postfix)
            POSTFIX=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
            COMPOSE_PROJECT_NAME="$(paste -d '-' <(echo "$TEST_NET_CTRL_NAME") <(echo "$POSTFIX"))"
            echo "$COMPOSE_PROJECT_NAME" > "$NAME_CACHE_FILE"
            ;;
        strict)
            COMPOSE_PROJECT_NAME="$TEST_NET_CTRL_NAME"
            echo "$COMPOSE_PROJECT_NAME" > "$NAME_CACHE_FILE"
            ;;
        *)
            panic "Invalid naming convention: $TEST_NET_CTRL_NAMING"
            ;;
    esac
fi

export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME"

case "$TEST_NET_CTRL_COMMAND" in
    up)
        up
        update
        ;;
    down)
        down
        ;;
    update)
        update
        ;;
esac
