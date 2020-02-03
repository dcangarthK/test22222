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

## auth and cert
ELASTIC_PASSWORD=$(oc get secret elasticsearch-es-elastic-user -o=jsonpath='{.data.elastic}' -n $NAMESPACE | base64 --decode)
oc get secret elasticsearch-es-http-ca-internal -o=jsonpath='{.data.tls\.crt}' -n $NAMESPACE | base64 --decode > /tmp/tls.crt
oc create secret generic logstash-es-cert --from-file=/tmp/tls.crt -n $NAMESPACE
rm /tmp/tls.crt

echo "creating ${RSRC_DIR}/logstash-config-configmap.yaml"
cat <<EOF > ${RSRC_DIR}/logstash-config-configmap.yaml
apiVersion: v1
data:
  logstash.yml: |-
    http.host: "0.0.0.0"
    xpack.monitoring.enabled: true
    xpack.monitoring.elasticsearch.username: elastic
    xpack.monitoring.elasticsearch.password: "${ELASTIC_PASSWORD}"
    xpack.monitoring.elasticsearch.hosts: [ "https://elasticsearch-es-http:9200" ]
    xpack.monitoring.elasticsearch.ssl.certificate_authority: /usr/share/logstash/certs/tls.crt
  jvm.options: |-
    ## JVM configuration

    # Xms represents the initial size of total heap space
    # Xmx represents the maximum size of total heap space

    -Xms768m
    -Xmx768m

    ################################################################
    ## Expert settings
    ################################################################
    ##
    ## All settings below this section are considered
    ## expert settings. Don't tamper with them unless
    ## you understand what you are doing
    ##
    ################################################################

    ## GC configuration
    -XX:+UseConcMarkSweepGC
    -XX:CMSInitiatingOccupancyFraction=75
    -XX:+UseCMSInitiatingOccupancyOnly

    ## Locale
    # Set the locale language
    #-Duser.language=en

    # Set the locale country
    #-Duser.country=US

    # Set the locale variant, if any
    #-Duser.variant=

    ## basic

    # set the I/O temp directory
    #-Djava.io.tmpdir=$HOME

    # set to headless, just in case
    -Djava.awt.headless=true

    # ensure UTF-8 encoding by default (e.g. filenames)
    -Dfile.encoding=UTF-8

    # use our provided JNA always versus the system one
    #-Djna.nosys=true

    # Turn on JRuby invokedynamic
    -Djruby.compile.invokedynamic=true
    # Force Compilation
    -Djruby.jit.threshold=0
    # Make sure joni regexp interruptability is enabled
    -Djruby.regexp.interruptible=true

    ## heap dumps

    # generate a heap dump when an allocation from the Java heap fails
    # heap dumps are created in the working directory of the JVM
    -XX:+HeapDumpOnOutOfMemoryError

    # specify an alternative path for heap dumps
    # ensure the directory exists and has sufficient space
    #-XX:HeapDumpPath=${LOGSTASH_HOME}/heapdump.hprof

    ## GC logging
    #-XX:+PrintGCDetails
    #-XX:+PrintGCTimeStamps
    #-XX:+PrintGCDateStamps
    #-XX:+PrintClassHistogram
    #-XX:+PrintTenuringDistribution
    #-XX:+PrintGCApplicationStoppedTime

    # log GC status to a file with time stamps
    # ensure the directory exists
    #-Xloggc:${LS_GC_LOG_FILE}

    # Entropy source for randomness
    -Djava.security.egd=file:/dev/urandom

    # Copy the logging context from parent threads to children
    -Dlog4j2.isThreadContextMapInheritable=true
  pipelines.yml: "# This file is where you define your pipelines. You can define multiple.\n#
    For more information on multiple pipelines, see the documentation:\n#   https://www.elastic.co/guide/en/logstash/current/multiple-pipelines.html\n\n-
    pipeline.id: main\n  path.config: \"/usr/share/logstash/pipeline\"  "
  startup.options: |-
    ################################################################################
    # These settings are ONLY used by $LS_HOME/bin/system-install to create a custom
    # startup script for Logstash and is not used by Logstash itself. It should
    # automagically use the init system (systemd, upstart, sysv, etc.) that your
    # Linux distribution uses.
    #
    # After changing anything here, you need to re-run $LS_HOME/bin/system-install
    # as root to push the changes to the init script.
    ################################################################################

    # Override Java location
    #JAVACMD=/usr/bin/java

    # Set a home directory
    LS_HOME=/usr/share/logstash

    # logstash settings directory, the path which contains logstash.yml
    LS_SETTINGS_DIR=/etc/logstash

    # Arguments to pass to logstash
    LS_OPTS="--path.settings ${LS_SETTINGS_DIR}"

    # Arguments to pass to java
    LS_JAVA_OPTS=""

    # pidfiles aren't used the same way for upstart and systemd; this is for sysv users.
    LS_PIDFILE=/var/run/logstash.pid

    # user and group id to be invoked as
    LS_USER=logstash
    LS_GROUP=logstash

    # Enable GC logging by uncommenting the appropriate lines in the GC logging
    # section in jvm.options
    LS_GC_LOG_FILE=/var/log/logstash/gc.log

    # Open file limit
    LS_OPEN_FILES=16384

    # Nice level
    LS_NICE=19

    # Change these to have the init script named and described differently
    # This is useful when running multiple instances of Logstash on the same
    # physical box or vm
    SERVICE_NAME="logstash"
    SERVICE_DESCRIPTION="logstash"
kind: ConfigMap
metadata:
  name: logstash-config
EOF

echo "creating ${RSRC_DIR}/logstash-pipeline-configmap.yaml"
cat <<EOF > ${RSRC_DIR}/logstash-pipeline-configmap.yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: logstash-pipeline
data:
  01-beats-input.conf: |-
    input {
      beats {
        port => 5044
        ssl => false
      }
    }
  02-http-input.conf: |-
    input {
      http {
        host => "0.0.0.0"
        port => 8080
      }
    }
  10-lsdbay-filter.conf: |-
    filter {
      if "lsdbay_log" in [tags] {
        mutate { add_tag => "lsdbay_event" }
        grok {
          match => { "message" => "%{SYSLOGTIMESTAMP:lsdbay_timestamp} lsdbay %{WORD:lsdbay_priority} %{GREEDYDATA:lsdbay_msg}" }
        }
        date {
          match => [ "lsdbay_timestamp", "MMM  d YYYY HH:mm:ss", "MMM dd YYYY HH:mm:ss", "MMM dd HH:mm:ss" ]
          timezone => "Africa/Johannesburg"
        }
      }
      if "lsdbay_event" in [tags] {
        if [lsdbay_msg] =~ "Login failed" {
          mutate { add_tag => "lsdbay_login_failed" }
          grok {
            match => { "lsdbay_msg" => "Login failed \- ip: %{IPORHOST:lsdbay_fsrcip}, username: %{NOTSPACE:lsdbay_fusername}, password: %{NOTSPACE:lsdbay_fpasswd}" }
          }
        }
        if [lsdbay_msg] =~ "Login succeeded" {
          mutate { add_tag => "lsdbay_login_succeeded" }
          grok {
            match => { "lsdbay_msg" => "Login succeeded \- ip: %{IPORHOST:lsdbay_srcip}, username: %{NOTSPACE:lsdbay_username}" }
          }
        }
        if [lsdbay_msg] =~ "Logout succeeded" {
          mutate { add_tag => "lsdbay_logout_succeeded" }
          grok {
            match => { "lsdbay_msg" => "Logout succeeded \- ip: %{IPORHOST:lsdbay_srcip}, userid: %{NUMBER:lsdbay_userid:int}, username: %{NOTSPACE:lsdbay_username}" }
          }
        }
        if [lsdbay_msg] =~ "Order succeeded" {
          mutate { add_tag => "lsdbay_order_succeeded" }
          grok {
            match => { "lsdbay_msg" => "Order succeeded \- ip: %{IPORHOST:lsdbay_srcip}, userid: %{NUMBER:lsdbay_userid:int}, username: %{NOTSPACE:lsdbay_username}, item: %{GREEDYDATA:lsdbay_item}, qty: %{NUMBER:lsdbay_qty:int}" }
          }
        }
      }
    }
  11-firewall-filter.conf: |-
    filter {
      if "firewall" in [tags] {
        grok {
          match => { "message" => "((%{SYSLOGTIMESTAMP:fw_timestamp})\s*(%{HOSTNAME:fw_host})\s*kernel\S+\s*(%{WORD:fw_action})?.*IN=(%{USERNAME:fw_in_interface})?.*OUT=(%{USERNAME:fw_out_interface})?.*MAC=(%{COMMONMAC:fw_dst_mac}):(%{COMMONMAC:fw_src_mac})?.*SRC=(%{IPV4:fw_src_ip}).*DST=(%{IPV4:fw_dst_ip}).*PROTO=(%{WORD:fw_protocol}).?*SPT=(%{INT:fw_src_port}?.*DPT=%{INT:fw_dst_port}?.*))" }
        }
        mutate {
          add_field => { "red_src" => "%{fw_src_ip}" }
        }
        date {
          match => [ "fw_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
          timezone => "Africa/Johannesburg"
        }
      }
    }
  12-secure-filter.conf: |-
    filter {
      if "secure" in [tags] {
        mutate { add_tag => "secure" }
        grok {
          match => { "message" => "%{SYSLOGTIMESTAMP:secure_timestamp} %{HOSTNAME:secure_hostname} %{GREEDYDATA:secure_msg}" }
        }
        date {
          match => [ "secure_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
          timezone => "Africa/Johannesburg"
        }
      }
      if "secure" in [tags] {
        if [secure_msg] =~ "sshd" {
          mutate { add_tag => "sshd" }
          grok {
            match => { "secure_msg" => "sshd\[%{NUMBER:sshd_pid:int}\]: %{GREEDYDATA:sshd_msg}" }
          }
        }
      }
      if "sshd" in [tags] {
        if [sshd_msg] =~ "Failed password for invalid user" {
          mutate { add_tag => "sshd_invalid_user" }
          grok {
            match => { "sshd_msg" => "Failed password for invalid user %{NOTSPACE:sshd_invalid_user} from %{IPORHOST:sshd_invalid_user_ip} port %{NUMBER:sshd_invalid_user_port} ssh2" }
          }
          mutate {
            add_field => { "red_src" => "%{sshd_invalid_user_ip}" }
          }
        }
      }
    }  
  30-es-output.conf: |-
    output {
      if "event_source" not in [fields] {
        elasticsearch {
          hosts => ["https://elasticsearch-es-http:9200"]
          ssl => true
          cacert => "/usr/share/logstash/certs/tls.crt"
          sniffing => false
          manage_template => false
          user => elastic
          password => "${ELASTIC_PASSWORD}"
          index => "logstash-%{+YYYY.MM.dd}"
        }
      } else {
        elasticsearch {
          hosts => ["https://elasticsearch-es-http:9200"]
          ssl => true
          cacert => "/usr/share/logstash/certs/tls.crt"
          sniffing => false
          manage_template => false
          user => elastic
          password => "${ELASTIC_PASSWORD}"
          index => "%{[fields][event_source]}-%{+YYYY.MM.dd}"
        }
      }
    }
EOF

echo "creating ${RSRC_DIR}/logstash-deployment.yaml"
cat <<EOF > ${RSRC_DIR}/logstash-deployment.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  labels:
    app: elastic
    component: logstash
  name: logstash
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: elastic
      component: logstash
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: elastic
        component: logstash
    spec:
      containers:
      - image: docker.elastic.co/logstash/logstash:7.5.1
        imagePullPolicy: IfNotPresent
        name: logstash
        ports:
        - containerPort: 5044
          protocol: TCP
        - containerPort: 8080
          protocol: TCP
        - containerPort: 9600
          protocol: TCP
        resources:
          limits:
            cpu: "1"
            memory: 1Gi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /usr/share/logstash/config
          name: logstash-config
        - mountPath: /usr/share/logstash/pipeline
          name: logstash-pipeline
        - mountPath: /usr/share/logstash/certs
          name: logstash-es-cert
          readOnly: true
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - configMap:
          defaultMode: 420
          name: logstash-config
        name: logstash-config
      - configMap:
          defaultMode: 420
          name: logstash-pipeline
        name: logstash-pipeline
      - name: logstash-es-cert
        secret:
          defaultMode: 420
          optional: false
          secretName: logstash-es-cert
EOF

echo "creating ${RSRC_DIR}/logstash-service.yaml"
cat <<EOF > ${RSRC_DIR}/logstash-service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app: elastic
    component: logstash
  name: logstash
spec:
  ports:
  - port: 5044
    protocol: TCP
    targetPort: 5044
    name: logstash-beats
  - port: 8080
    protocol: TCP
    targetPort: 8080
    name: logstash-http
  - port: 9600
    protocol: TCP
    targetPort: 9600
    name: logstash-monitor
  selector:
    app: elastic
    component: logstash
  sessionAffinity: None
  type: ClusterIP
EOF

oc create -f ${RSRC_DIR}/logstash-config-configmap.yaml -n $NAMESPACE
oc create -f ${RSRC_DIR}/logstash-pipeline-configmap.yaml -n $NAMESPACE
oc create -f ${RSRC_DIR}/logstash-service.yaml -n $NAMESPACE
oc create -f ${RSRC_DIR}/logstash-deployment.yaml -n $NAMESPACE
