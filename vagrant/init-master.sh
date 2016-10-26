#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=
export ETCD_NAME=

# List of etcd cluster servers (name=http://ip:port), comma separated
export ETCD_INITIAL_CLUSTER=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.3.0_coreos.1

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=index.tenxcloud.com/tuhuayuan/hyperkube

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the flannel overlay network.
export POD_NETWORK=10.2.0.0/16

# The CIDR network to use for service cluster IPs.
# Each service will be assigned a cluster IP out of this range.
# This must not overlap with any IP ranges assigned to the POD_NETWORK, or other existing network infrastructure.
# Routing to these IPs is handled by a proxy service local to each node, and are not required to be routable between nodes.
export SERVICE_IP_RANGE=10.3.0.0/24

# The IP address of the Kubernetes API Service
# If the SERVICE_IP_RANGE is changed above, this must be set to the first IP in that range.
export K8S_SERVICE_IP=10.3.0.1

# The IP address of the cluster DNS service.
# This IP must be in the range of the SERVICE_IP_RANGE and cannot be the first IP in the range.
# This same IP must be configured on all worker nodes to enable DNS service discovery.
export DNS_SERVICE_IP=10.3.0.10

# DNS domain of cluster
export CLUSTER_DOMAIN=

# Private IP of this node
export PRIVATE_IP=

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/etc/coreos-kubernetes/options.env

function init_config {
    local REQUIRED=('PRIVATE_IP' 'CLUSTER_DOMAIN' 'ETCD_NAME' 'ETCD_ENDPOINTS' 'ETCD_INITIAL_CLUSTER' 'POD_NETWORK' 'SERVICE_IP_RANGE' 'K8S_SERVICE_IP' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO')
   
    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    if [ -z $PRIVATE_IP ]; then
        export PRIVATE_IP=$(awk -F= '/COREOS_PRIVATE_IPV4/ {print $2}' /etc/environment)
    fi
    
    # Check all required varibles.
    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function init_templates {
  # kubernetes node config
  # ---------------------------
    
    local TEMPLATE=/etc/systemd/system/kubelet.service
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests \
                               /var/lib/docker \
                               /var/lib/kubelet \
                               /run/kubelet \
                               /var/log/containers
ExecStart=/usr/bin/rkt run \
  --volume etc-kubernetes,kind=host,source=/etc/kubernetes \
  --volume etc-ssl-certs,kind=host,source=/usr/share/ca-certificates \
  --volume var-lib-docker,kind=host,source=/var/lib/docker \
  --volume var-lib-kubelet,kind=host,source=/var/lib/kubelet \
  --volume run,kind=host,source=/run \
  --volume var-log-containers,kind=host,source=/var/log/containers \
  --mount volume=etc-kubernetes,target=/etc/kubernetes \
  --mount volume=etc-ssl-certs,target=/etc/ssl/certs \
  --mount volume=var-lib-docker,target=/var/lib/docker \
  --mount volume=var-lib-kubelet,target=/var/lib/kubelet \
  --mount volume=run,target=/run \
  --mount volume=var-log-containers,target=/var/log/containers \
  --trust-keys-from-https \
  --insecure-options=image \
  --stage1-path=/usr/share/rkt/stage1-fly.aci \
  docker://${HYPERKUBE_IMAGE_REPO}:${K8S_VER} \
  --exec=/hyperkube -- kubelet \
    --allow-privileged=true \
    --address=0.0.0.0 \
    --api-servers=http://127.0.0.1:8080 \
    --hostname-override=${ADVERTISE_IP} \
    --config=/etc/kubernetes/manifests \
    --cluster_dns=${DNS_SERVICE_IP} \
    --cluster_domain=${CLUSTER_DOMAIN} \
    --pod-infra-container-image=index.tenxcloud.com/tuhuayuan/pause:3.0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    }

    
    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${HYPERKUBE_IMAGE_REPO}:${K8S_VER}
    command:
    - /hyperkube
    - proxy
    - --master=http://127.0.0.1:8080
    - --proxy-mode=iptables
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    }

    local TEMPLATE=/etc/kubernetes/manifests/kube-apiserver.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: ${HYPERKUBE_IMAGE_REPO}:${K8S_VER}
    command:
    - /hyperkube
    - apiserver
    - --bind-address=0.0.0.0
    - --etcd-servers=${ETCD_ENDPOINTS}
    - --allow-privileged=true
    - --service-cluster-ip-range=${SERVICE_IP_RANGE}
    - --secure-port=443
    - --advertise-address=${ADVERTISE_IP}
    - --admission-control=NamespaceLifecycle,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota
    - --tls-cert-file=/etc/kubernetes/ssl/apiserver.pem
    - --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --client-ca-file=/etc/kubernetes/ssl/ca.pem
    - --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --runtime-config=extensions/v1beta1/deployments=true,extensions/v1beta1/daemonsets=true,extensions/v1beta1=true,extensions/v1beta1/thirdpartyresources=true
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 8080
      hostPort: 8080
      name: local
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    }

    local TEMPLATE=/etc/kubernetes/manifests/kube-controller-manager.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: ${HYPERKUBE_IMAGE_REPO}:${K8S_VER}
    command:
    - /hyperkube
    - controller-manager
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    - --service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --root-ca-file=/etc/kubernetes/ssl/ca.pem
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 1
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    }

    local TEMPLATE=/etc/kubernetes/manifests/kube-scheduler.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${HYPERKUBE_IMAGE_REPO}:${K8S_VER}
    command:
    - /hyperkube
    - scheduler
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10251
      initialDelaySeconds: 15
      timeoutSeconds: 1
EOF
    }

  
    local TEMPLATE=/srv/kubernetes/manifests/kube-system.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Namespace
metadata:
  name: kube-system
EOF
    }
    
    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-rc.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ReplicationController
metadata:
  name: kube-dns-v11
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    version: v11
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  selector:
    k8s-app: kube-dns
    version: v11
  template:
    metadata:
      labels:
        k8s-app: kube-dns
        version: v11
        kubernetes.io/cluster-service: "true"
    spec:
      containers: 
      - image: index.tenxcloud.com/tuhuayuan/kube2sky:1.15
        name: kube2sky
        args: 
        - --etcd-server=http://${ADVERTISE_IP}:4001
        - --domain=${CLUSTER_DOMAIN}
        resources:
          limits:
             cpu: 100m
             memory: 50Mi
          requests:
             cpu: 100m
             memory: 50Mi
      - image: index.tenxcloud.com/tuhuayuan/skydns:1.0
        name: skydns
        args:
        - -domain=${CLUSTER_DOMAIN}
        - -machines=${ETCD_ENDPOINTS}
        - -addr=0.0.0.0:53
        - -ns-rotate=false
        - -nameservers=202.101.224.68:53,202.101.226.68:53
        resources:
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 1
          timeoutSeconds: 5
      - image: index.tenxcloud.com/tuhuayuan/exec-healthz:1.1
        name: exec-healthz
        resources:
        limits:
          cpu: 10m
          memory: 20Mi
        requests:
          cpu: 10m
          memory: 20Mi
        args:
        - -cmd=nslookup kubernetes.default.svc.${CLUSTER_DOMAIN} 127.0.0.1 > /dev/null
        - -port=8080
        ports:
        - containerPort: 8080
          protocol: TCP
      dnsPolicy: Default
EOF
    }

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-svc.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP:  ${DNS_SERVICE_IP}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
    }

    local TEMPLATE=/srv/kubernetes/manifests/fluentd-es.yaml
     [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP:  ${DNS_SERVICE_IP}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
    }

    local TEMPLATE=/etc/systemd/system/etcd2.service.d/10-etcd2-config.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
Environment="ETCD_INITIAL_CLUSTER_STATE=new"
Environment="ETCD_NAME=${ETCD_NAME}"
Environment="ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER}"
Environment="ETCD_ADVERTISE_CLIENT_URLS=http://${ADVERTISE_IP}:2379"
Environment="ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${PRIVATE_IP}:2380"
Environment="ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379,http://0.0.0.0:4001"
Environment="ETCD_LISTEN_PEER_URLS=http://${PRIVATE_IP}:2380,http://${PRIVATE_IP}:7001"

EOF
    }
     
    local TEMPLATE=/etc/flannel/options.env
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
FLANNELD_IFACE=${ADVERTISE_IP}
FLANNELD_ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
EOF
    }

    local TEMPLATE=/etc/systemd/system/flanneld.service.d/10-set-environment.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
Environment="FLANNEL_IMG=index.tenxcloud.com/tuhuayuan/flannel"
Environment="FLANNEL_VER=0.5.5"
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF
    }

    local TEMPLATE=/etc/systemd/system/docker.service.d/10-flanneld.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF
    }

    local TEMPLATE=/etc/systemd/system/docker-tcp.socket
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Docker TCP Socket

[Socket]
ListenStream=2375
Service=docker.service
BindIPv6Only=both

[Install]
WantedBy=sockets.target
EOF
    }
}

function init_flannel {
    echo "Waiting for etcd..."
    while true
    do
        IFS=',' read -ra ES <<< "${ETCD_ENDPOINTS}"
        for ETCD in "${ES[@]}"; do
            echo "Trying: ${ETCD}"
            if [ -n "$(curl --silent "${ETCD}/v2/machines")" ]; then
                local ACTIVE_ETCD=$ETCD
                break
            fi
            sleep 1
        done
        if [ -n "${ACTIVE_ETCD}" ]; then
            break
        fi
    done
    RES=$(curl --silent -X PUT -d "value={\"Network\":\"${POD_NETWORK}\",\"Backend\":{\"Type\":\"vxlan\"}}" "${ACTIVE_ETCD}/v2/keys/coreos.com/network/config?prevExist=false")
    if [ -z "$(echo ${RES} | grep '"action":"create"')" ] && [ -z "$(echo ${RES} | grep 'Key already exists')" ]; then
        echo "Unexpected error configuring flannel pod network: ${RES}"
    fi
}

function start_addons {
    echo "Waiting for Kubernetes API..."
    until curl --silent "http://127.0.0.1:8080/version"
    do
        sleep 5
    done
    echo
    echo "K8S: kube-system namespace"
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-system.yaml)" "http://127.0.0.1:8080/api/v1/namespaces" > /dev/null
    echo "K8S: DNS addon"
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-rc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/replicationcontrollers" > /dev/null
    curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
    echo "K8S: Fluentd for logging"
  # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/es-controller.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/replicationcontrollers" > /dev/null
  # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/es-service.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
  # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kibana-controller.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/replicationcontrollers" > /dev/null
  # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kibana-service.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
  # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/fluentd-es.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/daemonsets" > /dev/null
  #  echo "K8S: Router"
  #  curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/deis-router.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/daemonsets" > /dev/null
}

function start_nfs_server {
    echo "Start nfs server."
    mkdir -p /nfs/exports
    local TEMPLATE=/etc/exports
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
/nfs/exports *(rw,async,no_subtree_check,no_root_squash,fsid=0)
EOF
    }

    systemctl start rpc-mountd; systemctl start nfsd
}

init_config
init_templates

systemctl daemon-reload
systemctl stop update-engine; systemctl mask update-engine
systemctl restart nfs-utils
systemctl enable etcd2; systemctl start etcd2
init_flannel
systemctl enable docker-tcp.socket; systemctl start docker-tcp.socket     
systemctl enable flanneld; systemctl start flanneld
systemctl enable kubelet; systemctl start kubelet
start_addons
start_nfs_server

echo "DONE"
