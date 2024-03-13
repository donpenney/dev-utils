#!/bin/bash
#
# Run a local etcd server and delete all the leader leases
#

PROG=$(basename "$0")

function log {
    echo "${PROG}: $*"
}

function cleanup {
    if ! podman container exists local_etcd; then
        return
    fi

    # Stop the local_etcd
    log "Shutting down local_etcd"
    if ! podman stop local_etcd ; then
        log "Failed to stop local_etcd. Killing container"
        if ! podman kill local_etcd ; then
            log "Failed to kill local_etcd"
            exit 1
        fi
    fi
}

trap cleanup EXIT

set -x

MANIFEST=/etc/kubernetes/manifests/etcd-pod.yaml
if [ ! -f "${MANIFEST}" ]; then
    log "Static pod manifest not found: ${MANIFEST}"
    exit 1
fi

# Find the etcd image from the static pod manifest
ETCD_IMAGE=$(jq -r '.spec.containers[] | select(.name == "etcd") | .image' <${MANIFEST})
if [ -z "${ETCD_IMAGE}" ]; then
    log "Unable to determine etcd image from static pod manifest"
    exit 1
fi

# Launch local etcd
log "Launching local_etcd container"
if ! podman run --name local_etcd --rm --replace --detach --privileged \
    --entrypoint etcd -v /var/lib/etcd:/store \
    "${ETCD_IMAGE}" --name editor --data-dir /store ; then
    log "Unable to run local_etcd container"
    exit 1
fi

# Delete all leases
log "Deleting leases"
if ! podman exec local_etcd etcdctl del --prefix /kubernetes.io/leases/ --command-timeout=60s ; then
    log "Failed to delete leases"
    exit 1
fi

# Ensure /etc/docker/certs.d exists, to avoid MCP degradation issue
if [ ! -d /etc/docker/certs.d ]; then
    mkdir -p /etc/docker/certs.d
fi

exit 0

