#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=
export ETCD_NAME=

# Master apiserver http://ip:port;.......
export MASTER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.3.0_coreos.1

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=index.tenxcloud.com/tuhuayuan/hyperkube

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# DNS domain of cluster
export CLUSTER_DOMAIN=

# Private IP of this node
export PRIVATE_IP=

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/etc/coreos-kubernetes/options.env

# -------------

function init_config {
    local REQUIRED=('CLUSTER_DOMAIN' 'ETCD_NAME' 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'MASTER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO')

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    if [ -z $PRIVATE_IP ]; then
        export PRIVATE_IP=$(awk -F= '/PRIVATE_IP/ {print $2}' /etc/environment)
    fi

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
                               /run/kubelet
ExecStart=/usr/bin/rkt run \
  --volume etc-kubernetes,kind=host,source=/etc/kubernetes \
  --volume etc-ssl-certs,kind=host,source=/usr/share/ca-certificates \
  --volume var-lib-docker,kind=host,source=/var/lib/docker \
  --volume var-lib-kubelet,kind=host,source=/var/lib/kubelet \
  --volume run,kind=host,source=/run \
  --mount volume=etc-kubernetes,target=/etc/kubernetes \
  --mount volume=etc-ssl-certs,target=/etc/ssl/certs \
  --mount volume=var-lib-docker,target=/var/lib/docker \
  --mount volume=var-lib-kubelet,target=/var/lib/kubelet \
  --mount volume=run,target=/run \
  --trust-keys-from-https \
  --insecure-options=image \
  --stage1-path=/usr/share/rkt/stage1-fly.aci \
  docker://${HYPERKUBE_IMAGE_REPO}:${K8S_VER} \
  --exec=/hyperkube -- kubelet \
    --allow-privileged=true \
    --api-servers=${MASTER_ENDPOINT} \
    --hostname-override=${ADVERTISE_IP} \
    --config=/etc/kubernetes/manifests \
    --hostname-override=${ADVERTISE_IP} \
    --cluster_dns=${DNS_SERVICE_IP} \
    --cluster_domain=${CLUSTER_DOMAIN} \
    --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
    --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
    --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
    --pod-infra-container-image=index.tenxcloud.com/tuhuayuan/pause:3.0
    
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    }

    local TEMPLATE=/etc/kubernetes/worker-kubeconfig.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: /etc/kubernetes/ssl/ca.pem
users:
- name: kubelet
  user:
    client-certificate: /etc/kubernetes/ssl/worker.pem
    client-key: /etc/kubernetes/ssl/worker-key.pem
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
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
    - --master=${MASTER_ENDPOINT}
    - --proxy-mode=iptables
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
    - mountPath: /etc/kubernetes
      name: kube-config
      readOnly: true
  volumes:
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
  - hostPath:
      path: /etc/kubernetes/
    name: kube-config
EOF
    }

# coreos configs
# -----------------------------------

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

function wait_etcd2 {
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
    echo "Find a etcd endpoint ${ACTIVE_ETCD}"
}

init_config
init_templates

systemctl daemon-reload

# allow kubelet mount nfs pv.
systemctl start rpc-statd
systemctl stop update-engine; systemctl mask update-engine
# start etcd2 -> docker-tcp -> flanneld -> kubelet
systemctl enable etcd2; systemctl start etcd2
wait_etcd2
systemctl enable docker-tcp.socket; systemctl start docker-tcp.socket
systemctl enable flanneld; systemctl start flanneld
systemctl enable kubelet; systemctl start kubelet

echo "DONE"
