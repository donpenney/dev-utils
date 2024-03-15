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

function clusterIsSNO {
    local json=
    local controlPlaneTopology=
    local infrastructureTopology=
    local clusterCR="/kubernetes.io/config.openshift.io/infrastructures/cluster"
    json=$(podman exec local_etcd etcdctl get "${clusterCR}" --print-value-only)
    controlPlaneTopology=$(echo "${json}" | jq -r '.status.controlPlaneTopology')
    infrastructureTopology=$(echo "${json}" | jq -r '.status.infrastructureTopology')

    if [ "${controlPlaneTopology}" != "SingleReplica" ] || [ "${infrastructureTopology}" != "SingleReplica" ]; then
        log "Cluster is not SNO: controlPlaneTopology=${controlPlaneTopology}, infrastructureTopology=${infrastructureTopology}"
        return 1
    fi

    return 0
}

function lcaNamespaceExists {
    local lcaNs="/kubernetes.io/namespaces/openshift-lifecycle-agent"
    [ "$(podman exec local_etcd etcdctl get ${lcaNs} --keys-only)" = "${lcaNs}" ]
}

function deleteKey {
    local key="$1"
    if [ "$(podman exec local_etcd etcdctl get ${key} --keys-only)" = "${key}" ]; then
        log "Deleting ${key}"
        podman exec local_etcd etcdctl del "${key}"
    fi
}

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

# Exit without making changes, if not SNO
if ! clusterIsSNO; then
    log "Cluster is not SNO. Exiting without changes"
    exit 0
fi

# Exit without making changes, if no LCA
if ! lcaNamespaceExists; then
    log "LCA is not installed. Exiting without changes"
    exit 0
fi

# Delete all leases
log "Deleting leases"
if ! podman exec local_etcd etcdctl del --prefix /kubernetes.io/leases/ --command-timeout=60s ; then
    log "Failed to delete leases"
    exit 1
fi

# In 4.14, there are some pods using configmap locks, rather than lease locks, for leader election.
# Delete these specific entries, if they exist
deleteKey "/kubernetes.io/configmaps/openshift-cloud-credential-operator/cloud-credential-operator-leader"
deleteKey "/kubernetes.io/configmaps/openshift-cluster-version/version"
deleteKey "/kubernetes.io/configmaps/openshift-controller-manager/openshift-master-controllers"
deleteKey "/kubernetes.io/configmaps/openshift-marketplace/marketplace-operator-lock"

# Ensure /etc/docker/certs.d exists, to avoid MCP degradation issue
if [ ! -d /etc/docker/certs.d ]; then
    mkdir -p /etc/docker/certs.d
fi

exit 0

