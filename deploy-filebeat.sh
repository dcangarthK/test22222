#!/bin/bash

BIN_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
RSRC_DIR="${BIN_DIR}/resources"

if [[ -z "$NAMESPACE" ]]; then
    echo
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide NAMESPACE in environment" 1>&2
    echo "This is the namespace we will be deploying filebeats daemonset to"
    echo
    echo "For example..."
    echo "export NAMESPACE=madapi-elastic"
    echo
    exit 1
fi

cp ${RSRC_DIR}/filebeat-kubernetes.yaml /tmp/filebeat-kubernetes.yaml
sed -i s/CHANGE_NAMESPACE/$NAMESPACE/g /tmp/filebeat-kubernetes.yaml

oc adm policy add-scc-to-user privileged -z filebeat -n $NAMESPACE
oc create -f /tmp/filebeat-kubernetes.yaml -n $NAMESPACE
rm -f /tmp/filebeat-kubernetes.yaml
