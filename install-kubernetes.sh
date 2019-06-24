#!/bin/bash

export KUBERNETES_VERSION="1.14.3"

echo "=== Installing Kubernetes ${KUBERNETES_VERSION} ==="

LOGFILE=/var/log/install-kubernetes.log
echo "Installation log is in ${LOGFILE}"

tail -f ${LOGFILE} &
TAIL_PID=$!
trap "kill ${TAIL_PID}" EXIT
exec &> ${LOGFILE}

set -o verbose
set -o errexit
set -o pipefail

set -o nounset

export DNS_NAME=${1}    # First parameter - FQDN

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

# Disable SELinux
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

yum install -y kubelet-${KUBERNETES_VERSION} kubeadm-${KUBERNETES_VERSION} kubectl-${KUBERNETES_VERSION} kubernetes-cni

# Add --cloud-provider=aws to kubelet args
sed -i 's/^KUBELET_EXTRA_ARGS=\(.*\)/KUBELET_EXTRA_ARGS="--cloud-provider=aws \1"/' /etc/sysconfig/kubelet

# Start services
systemctl enable docker
systemctl start docker
systemctl enable kubelet
systemctl start kubelet

# Settings needed by Docker
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
kubeadm init --config /tmp/kubeadm.yaml

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

# Copy kubeconfig to 'centos' user home
mkdir /home/centos/.kube
cp /etc/kubernetes/admin.conf /home/centos/.kube/config
chown centos:centos /home/centos/.kube/config
chmod 0600 /home/centos/.kube/config

# Set $KUBECONFIG for root
echo "export KUBECONFIG=${KUBECONFIG}" >> /root/.bashrc

# Load addons
for ADDON in addons/*.yaml
do
  cat $ADDON | envsubst > /tmp/addon.yaml
  kubectl apply -f /tmp/addon.yaml
  rm /tmp/addon.yaml
done
