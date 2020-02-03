#!/bin/bash

BIN_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
RSRC_DIR="${BIN_DIR}/resources"

if [[ -z "$NAMESPACE" ]]; then
    echo
    echo  -e "\033[33;5mError\033[0m"
    echo
    echo "Must provide NAMESPACE in environment" 1>&2
    echo "This is the namespace we will be deploying APM to"
    echo
    echo "For example..."
    echo "export NAMESPACE=madapi-elastic"
    echo
    exit 1
fi

## auth and cert
ELASTIC_PASSWORD=$(oc get secret elasticsearch-es-elastic-user -o=jsonpath='{.data.elastic}' -n $NAMESPACE | base64 --decode)

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: apm.k8s.elastic.co/v1beta1
kind: ApmServer
metadata:
  name: apm-server
spec:
  version: 7.5.1
  count: 1
  secureSettings:
  - secretName: apm-secret-settings
  config:
    output:
      elasticsearch:
        hosts: ["https://elasticsearch-es-http:9200"]
        username: elastic
        password: "${ELASTIC_PASSWORD}"
        protocol: "https"
        ssl.certificate_authorities: ["/usr/share/apm-server/config/elasticsearch-ca/tls.crt"]
  podTemplate:
    spec:
      containers:
      - name: apm-server
        securityContext:
          privileged: true
        volumeMounts:
        - mountPath: /usr/share/apm-server/config/elasticsearch-ca
          name: elasticsearch-ca
          readOnly: true
      volumes:
      - name: elasticsearch-ca
        secret:
          defaultMode: 420
          optional: false
          secretName: logstash-es-cert
EOF
