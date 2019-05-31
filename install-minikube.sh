#!/bin/bash

echo "=== Installing minikube ==="
echo "Installation log is in /var/log/install-minikube.log"

LOGFILE=/var/log/install-minikube.log
tail -f ${LOGFILE} &
TAIL_PID=$!
trap "kill ${TAIL_PID}" EXIT
exec &> ${LOGFILE}

set -o verbose
set -o errexit
set -o pipefail

set -o nounset

export DNS_NAME=${1}    # First parameter - FQDN
export KUBERNETES_VERSION="1.14.1"

# Figure out the some more settings
export IP_ADDRESS=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
export CLUSTER_NAME=$(cut -d. -f1 <<< "${DNS_NAME}")

# See https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/ for the required format
export KUBEADM_TOKEN=$(base64 -w100 /dev/urandom | awk 'NR==1{gsub("[^a-z0-9]", ""); print substr($0, 0, 6) "." substr($0, 6, 16); exit; }')

# We needed to match the hostname expected by kubeadm an the hostname used by kubelet
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"

# Make DNS lowercase
DNS_NAME=$(echo "$DNS_NAME" | tr 'A-Z' 'a-z')

# Install docker
yum install -y yum-utils curl gettext device-mapper-persistent-data lvm2 docker

# Install Kubernetes components
sudo cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
        https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

# setenforce returns non zero if already SE Linux is already disabled
is_enforced=$(getenforce)
if [[ $is_enforced != "Disabled" ]]; then
  setenforce 0
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/sysconfig/selinux
fi

yum install -y kubelet-$KUBERNETES_VERSION kubeadm-$KUBERNETES_VERSION kubernetes-cni

# Fix kubelet configuration
sed -i 's/--cgroup-driver=systemd/--cgroup-driver=cgroupfs/g' /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
sed -i '/Environment="KUBELET_CGROUP_ARGS/i Environment="KUBELET_CLOUD_ARGS=--cloud-provider=aws"' /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
sed -i 's/$KUBELET_CGROUP_ARGS/$KUBELET_CLOUD_ARGS $KUBELET_CGROUP_ARGS/g' /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

# Start services
systemctl enable docker
systemctl start docker
systemctl enable kubelet
systemctl start kubelet

# Set settings needed by Docker
sysctl net.bridge.bridge-nf-call-iptables=1
sysctl net.bridge.bridge-nf-call-ip6tables=1

# Initialize the master
cat >/tmp/kubeadm.yaml <<EOF
---

apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: $KUBEADM_TOKEN
  ttl: 0s
  usages:
  - signing
  - authentication
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  kubeletExtraArgs:
    cloud-provider: aws
    read-only-port: "10255"
  name: $FULL_HOSTNAME
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---

apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
apiServer:
  certSANs:
  - $DNS_NAME
  - $IP_ADDRESS
  extraArgs:
    cloud-provider: aws
  timeoutForControlPlane: 5m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager:
  extraArgs:
    cloud-provider: aws
dns:
  type: CoreDNS
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: k8s.gcr.io
kubernetesVersion: v$KUBERNETES_VERSION
networking:
  dnsDomain: cluster.local
  podSubnet: ""
  serviceSubnet: 10.96.0.0/12

EOF

kubeadm reset --force
kubeadm init --config /tmp/kubeadm.yaml #--ignore-preflight-errors=SystemVerification

# Use the local kubectl config for further kubectl operations
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install calico
kubectl apply -f scripts/calico.yaml

# Allow all apps to run on master
kubectl taint nodes --all node-role.kubernetes.io/master-

# Allow load balancers to route to master
kubectl label nodes --all node-role.kubernetes.io/master-

# Allow the user to administer the cluster
kubectl create clusterrolebinding admin-cluster-binding --clusterrole=cluster-admin --user=admin

# Prepare the kubectl config file for download to client (IP address)
export KUBECONFIG_OUTPUT=/home/centos/kubeconfig_ip
kubeadm alpha kubeconfig user \
  --client-name admin \
  --apiserver-advertise-address $IP_ADDRESS \
  > $KUBECONFIG_OUTPUT
chown centos:centos $KUBECONFIG_OUTPUT
chmod 0600 $KUBECONFIG_OUTPUT

cp /home/centos/kubeconfig_ip /home/centos/kubeconfig
sed -i "s/server: https:\/\/$IP_ADDRESS:6443/server: https:\/\/$DNS_NAME:6443/g" /home/centos/kubeconfig
chown centos:centos /home/centos/kubeconfig
chmod 0600 /home/centos/kubeconfig

# Load addons
for ADDON in addons/*.yaml
do
  cat $ADDON | envsubst > /tmp/addon.yaml
  kubectl apply -f /tmp/addon.yaml
  rm /tmp/addon.yaml
done

