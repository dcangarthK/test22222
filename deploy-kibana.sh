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
    echo "export NAMESPACE=madapi-elastic"
    echo
    exit 1
fi

if [[ -z "$KIBANAHOSTNAME" ]]; then
    echo
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide KIBANAHOSTNAME in environment" 1>&2
    echo "This is the hostname/url we will be setting up fro the route for Kibana"
    echo
    echo "For example..."
    echo "export KIBANAHOSTNAME=kibana-madapi.apps.cluster-01.az-euwest.api.mtn.com"
    echo
    exit 1
fi

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: kibana.k8s.elastic.co/v1beta1
kind: Kibana
metadata:
  name: kibana
spec:
  version: 7.5.1
  count: 1
  elasticsearchRef:
    name: elasticsearch
  podTemplate:
    metadata:
      labels:
        component: kibana
        app: elastic
    spec:
      containers:
      - name: kibana
        resources:
          limits:
            memory: 1Gi
            cpu: 1
EOF

sleep 10

oc get secret kibana-kb-http-ca-internal -o=jsonpath='{.data.tls\.crt}' -n $NAMESPACE | base64 --decode > /tmp/tls.crt

cat <<EOF > ${RSRC_DIR}/kb-route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    common.k8s.elastic.co/type: kibana
    kibana.k8s.elastic.co/name: kibana
  name: kibana
spec:
  host: $KIBANAHOSTNAME
  port:
    targetPort: 5601
  subdomain: ""
  to:
    kind: Service
    name: kibana-kb-http
    weight: 100
  wildcardPolicy: None
  tls:
    insecureEdgeTerminationPolicy: None
    termination: reencrypt
    destinationCACertificate: |-
EOF

cat /tmp/tls.crt | sed -e "s/^/      /" >>${RSRC_DIR}/kb-route.yaml
rm /tmp/tls.crt

oc create -f ${RSRC_DIR}/kb-route.yaml -n $NAMESPACE

PASSWORD=$(oc get secret elasticsearch-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode)

echo
echo "You can log into Kibana using the follwing details"
echo "https://$KIBANAHOSTNAME"
echo "user: elastic"
echo "password: $PASSWORD"
