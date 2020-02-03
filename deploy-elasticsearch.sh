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

if [[ -z "$ELASTICNAME" ]]; then
    echo
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide ELASTICNAME in environment" 1>&2
    echo "This is the name of the Elasticsearch cluster"
    echo
    echo "For example..."
    echo "export ELASTICNAME=test-elastic"
    echo
    exit 1
fi

if [[ -z "$PVCSIZE" ]]; then
    echo 
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide PVCSIZE in environment" 1>&2
    echo "This is the size of the PVC volumes that will be created"
    echo
    echo "For example..."
    echo "export PVCSIZE=50Gi"
    echo
    exit 1
fi


# below is required if setting node.store.allow_mmap: true - you cannot add a privileged sa to the elastic custom resource
# workaround for future deployments is to either PR or deploy elastic to an isolated namespace

# note - oc get Tuned/default -o yaml -n openshift-cluster-node-tuning-operator - should be possible to set vm.max_map_count=262144
# globally via the tuned operator and avoid the need for a privileged init container

# note - theres an example of this for a openshift-node-es node type here: https://docs.openshift.com/container-platform/4.2/scalability_and_performance/using-node-tuning-operator.html#using-node-tuning-operator
oc adm policy add-scc-to-user privileged -z default -n $NAMESPACE

cat <<EOF | oc apply -f -
apiVersion: elasticsearch.k8s.elastic.co/v1beta1
kind: Elasticsearch
metadata:
  name: elasticsearch
spec:
  version: 7.5.1
  nodeSets:
  - name: $ELASTICNAME
    count: 1
    config:
      node.master: true
      node.data: true
      node.ingest: true
      node.store.allow_mmap: true
    podTemplate:
      metadata:
        labels:
          component: elasticsearch
          app: elastic
      spec:
        initContainers:
        - name: sysctl
          serviceAccount: elasticsearch
          serviceAccountName: elasticsearch
          securityContext:
            privileged: true
          command: ['sh', '-c', 'sysctl -w vm.max_map_count=262144']
        containers:
        - name: elasticsearch
          serviceAccount: elasticsearch
          serviceAccountName: elasticsearch
          resources:
            limits:
              memory: 2Gi
              cpu: 1
          env:
          - name: ES_JAVA_OPTS
            value: "-Xms1g -Xmx1g"
    count: 3
    volumeClaimTemplates:
      - metadata:
          name: elasticsearch-data
        spec:
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: $PVCSIZE
EOF

sleep 10
oc get secret elasticsearch-es-http-ca-internal -o=jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/tls.crt

cat <<EOF > ${RSRC_DIR}/es-route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    common.k8s.elastic.co/type: elasticsearch
    elasticsearch.k8s.elastic.co/cluster-name: elasticsearch
  name: elasticsearch
spec:
  port:
    targetPort: 9200
  subdomain: ""
  to:
    kind: Service
    name: elasticsearch-es-http
    weight: 100
  wildcardPolicy: None
  tls:
    insecureEdgeTerminationPolicy: None
    termination: reencrypt
    destinationCACertificate: |-
EOF

cat /tmp/tls.crt | sed -e "s/^/      /" >>${RSRC_DIR}/es-route.yaml
rm /tmp/tls.crt

oc create -f ${RSRC_DIR}/es-route.yaml
