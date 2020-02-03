#!/bin/bash

BIN_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
RSRC_DIR="${BIN_DIR}/resources"

if [[ -z "$NAMESPACE" ]]; then
    echo 
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide NAMESPACE in environment" 1>&2
    echo "This is the namespace we will be deploying elasticsearch to"
    echo
    echo "For example..."
    echo "export NAMESPACE=test-elastic"
    echo
    exit 1
fi

oc new-project $NAMESPACE
oc patch namespace $NAMESPACE --patch '{ "metadata":{"annotations": {"openshift.io/node-selector": "" }}}'
