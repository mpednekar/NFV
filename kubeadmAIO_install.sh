#!/bin/bash

#Uncomment out this if you want full debug output
#set -xe

# This script can be used to setup the Kubeadm All-in-One environment on Ubuntu 16.04.
# This script should not be run as root but as a different user. Create a new user
# and give it root privileges if required.

if [[ $EUID -eq 0 ]]; then echo "This script should not be run using sudo or as the root user"; exit 1; fi

### Declare colors to use during the running of this script:
declare -r GREEN="\033[0;32m"
declare -r RED="\033[0;31m"
declare -r YELLOW="\033[0;33m"

function echo_green {
  echo -e "${GREEN}$1"; tput sgr0
}
function echo_red {
  echo -e "${RED}$1"; tput sgr0
}
function echo_yellow {
  echo -e "${YELLOW}$1"; tput sgr0
}

cd ~/

echo "----- Setup etc/hosts"
#Setup etc/hosts
HOST_IFACE=$(ip route | grep "^default" | head -1 | awk '{ print $5 }')
LOCAL_IP=$(ip addr | awk "/inet/ && /${HOST_IFACE}/{sub(/\/.*$/,\"\",\$2); print \$2}")
cat << EOF | sudo tee -a /etc/hosts
${LOCAL_IP} $(hostname)
EOF


#Installs the latest verisions of vim, curl, git, nfs-common, make, and docker.io
#Installing docker.io this way rather than from the base is required because of api changes within docker that break osh

echo_green "\nPhase I: Installing system prerequisites:"
pkg="vim curl git nfs-common make docker.io"

for pkg in $pkg; do
    if sudo dpkg --get-selections | grep -q "^$pkg[[:space:]]*install$" >/dev/null; then
        echo_yellow "$pkg is already installed"
    else
        sudo apt-get update && sudo apt-get -qq install $pkg
        echo_green "Successfully installed $pkg"
    fi
done

#Start and enable docker if it isn't already running
echo "---- check if docker running"
if sudo docker ps
then
	echo "----- skip docker"
else
	echo "----- start docker"
	sudo systemctl start docker
  sudo systemctl enable docker
fi

echo "----- Downloads and installs kubectl, the command line interface for running"
#Downloads and installs kubectl, the command line interface for running
#commands against your Kubernetes cluster.
export KUBE_VERSION=v1.6.8
export HELM_VERSION=v2.5.1
export TMP_DIR=$(mktemp -d)
export OSH_VER=dbfbbda82689d0436bd39d36c8738c2d4e12fb7b
export MARIADB_SIZE=15Gi

curl -sSL https://storage.googleapis.com/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kubectl -o ${TMP_DIR}/kubectl
chmod +x ${TMP_DIR}/kubectl
sudo mv ${TMP_DIR}/kubectl /usr/local/bin/kubectl

echo "----- #Downloads and installs Helm, the package manager for Kubernetes"
curl -sSL https://storage.googleapis.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -zxv --strip-components=1 -C ${TMP_DIR}
sudo mv ${TMP_DIR}/helm /usr/local/bin/helm
rm -rf ${TMP_DIR}

#Remove the copenstack-helm directory and all of its contents
#TODO: Make this idempotent
rm -rf openstack-helm

echo "----- #Clones the repository that holds all of the OpenStack service charts."
git clone https://github.com/openstack/openstack-helm.git
cd openstack-helm
git checkout ${OSH_VER}

#Kill the helm serve process
pkill -f 'helm serve'

#Remove the .helm directory and all of it's contents
rm -rf ~/.helm

echo "----- #Initialize the helm client and start listening on localhost:8879."
helm init --client-only

#Using the Dockerfile defined in tools/kubeadm-aio directory,
#this builds the openstackhelm/kubeadm-aio:v1.6.8 image.
export KUBEADM_IMAGE=openstackhelm/kubeadm-aio:${KUBE_VERSION}
sudo docker build --pull -t ${KUBEADM_IMAGE} $(pwd)/tools/kubeadm-aio

### WAIT FOR KUBERNETES ENVIRONMENT TO COME UP:
echo -e -n "Waiting for Kubeadm-AIO container to build..."
while true; do
  aio_exist=$(sudo docker images 2>/dev/null | grep "openstackhelm/kubeadm-aio" | wc -l)
  ### Expect all components to be out of a "ContainerCreating" state before collecting log data (this includes CrashLoopBackOff states):
  if [ "$aio_exist" -ge 1 ]; then
    break
  fi
  echo -n "."
  sleep 2
done
echo_green "SUCCESS"
echo_green "Container built!"
echo ""


#After the image is built, execute the kubeadm-aio-launcher script
#which creates a single node Kubernetes environment by default with Helm,
#Calico, an NFS PVC provisioner with appropriate RBAC rules and node labels
#to start developing. The following deploys the Kubeadm-AIO environment.
./tools/kubeadm-aio/kubeadm-aio-launcher.sh
export KUBECONFIG=${HOME}/.kubeadm-aio/admin.conf
mkdir -p  ${HOME}/.kube
cat ${KUBECONFIG} > ${HOME}/.kube/config

### WAIT FOR TILLER DEPLOYEMENT TO COME UP:
echo -e -n "Waiting for Tiller pods to build..."
while true; do
  tiller_exist=$(sudo kubectl get pods --namespace kube-system | grep "tiller" | grep "Running" | grep "1/1" | wc -l)
  if [ "$tiller_exist" -ge 1 ]; then
    echo "Tiller Running!!"
    break
  fi
  echo -n "."
  sleep 2
done

#Once the helm client is available, add the local repository to the helm client.
helm serve &
sleep 30
helm repo add local http://localhost:8879/charts
helm repo remove stable


#The provided Makefile in OpenStack-Helm will perform the following:
#Lint: Validate that your helm charts have no basic syntax errors.
#Package: Each chart will be compiled into a helm package that will contain
#all of the resource definitions necessary to run an application,tool,
#or service inside of a Kubernetes cluster.
#Push: Push the Helm packages to your local Helm repository.
make

#Using the Helm packages previously pushed to the local Helm repository,
#run the following commands to instruct tiller to create an instance of
#the given chart. During installation, the helm client will print useful
#information about resources created, the state of the Helm releases,
#and whether any additional configuration steps are necessary.
helm install --name=mariadb local/mariadb --set volume.size=${MARIADB_SIZE} --namespace=openstack
echo -e -n "Waiting for all MariaDB members to come online..."
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "mariadb" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 3 ]; then
    break
  fi
  echo -n "."
  sleep 2
done
echo_green "SUCCESS"
echo_green "MariaDB deployed!"
echo ""
helm install --name=memcached local/memcached --namespace=openstack
helm install --name=etcd-rabbitmq local/etcd --namespace=openstack
helm install --name=rabbitmq local/rabbitmq --namespace=openstack
echo -e -n "Waiting for RabbitMQ members to come online..."
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "rabbitmq" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 3 ]; then
    break
  fi
  echo -n "."
  sleep 2
done
echo_green "SUCCESS"
echo_green "RabbitMQ deployed!"
echo ""

helm install --name=ingress local/ingress --namespace=openstack
echo -e -n "Waiting for ingress to come online..."
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "ingress" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 2 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "Ingress is now ready!"
echo ""

#Once the OpenStack infrastructure components are installed and running,
#the OpenStack services can be installed. In the below examples the default
#values that would be used in a production-like environment have been
#overridden with more sensible values for the All-in-One environment using
#the --values and --set options.
helm install --name=keystone local/keystone --namespace=openstack
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "keystone" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 1 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "keystone is now ready!"
echo ""

helm install --name=glance local/glance --namespace=openstack \
  --values=./tools/overrides/mvp/glance.yaml
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "glance" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 2 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "glance is now ready!"
echo ""

helm install --name=nova local/nova --namespace=openstack \
  --values=./tools/overrides/mvp/nova.yaml \
  --set=conf.nova.libvirt.nova.conf.virt_type=qemu
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "nova" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 7 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "nova is now ready!"
echo ""

helm install --name=neutron local/neutron \
  --namespace=openstack --values=./tools/overrides/mvp/neutron.yaml
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "neutron" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 4 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "neutron is now ready!"
echo ""

helm install --name=horizon local/horizon --namespace=openstack \
  --set=network.enable_node_port=true
while true; do
  running_count=$(kubectl get pods -n openstack --no-headers 2>/dev/null | grep "horizon" | grep "Running" | grep "1/1" | wc -l)
  if [ "$running_count" -ge 1 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
echo_green "SUCCESS"
echo_green "horizon is now ready!"
echo ""


#Once the install commands have been issued, executing the following will
#provide insight into the services deployment status.
#watch kubectl get pods --namespace=openstack
