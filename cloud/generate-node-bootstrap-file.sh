#!/usr/bin/env bash

RUNC_VERSION="1.4.3"
CONTAINERD_VERSION="2.3.3"

AUTH_TYPE_ARC="arc"
AUTH_TYPE_ARCCSR="arccsr"
AUTH_TYPE_AZURE="azure"
AUTH_TYPE_AZURECSR="azurecsr"
AUTH_TYPE_BOOTSTRAP="bootstrap"

DOWNLOAD_MODE_DIRECT="direct"
DOWNLOAD_MODE_MARINER="mariner"
DOWNLOAD_MODE_UBUNTU="ubuntu"
DOWNLOAD_MODE_NONE="none"

NODE_POOL="nodepool1"
NODE_MODE="user"
DOWNLOAD_MODE="none"
AKS_AAD_SERVER_ID="6dae42f8-4368-4678-94ff-3960e28e3630"
SYSTEMD_DIRECTORY=/etc/systemd/system/
KUBELET_LOCATION=/usr/local/bin
RUNC_PATH=/usr/bin/runc

logValue() {
    local NAME=$1
    local VALUE=$2

    printf "%25s: %s\n" "$NAME" "$VALUE"
}

logProgress() {
    echo "$1"
}
logProgress2() {
    echo "  - $1"
}

helpFunction() {
    echo "Usage: "
    echo "  -i <ARM Cluster Identifier> (required)"
    echo "  -a node join: ${AUTH_TYPE_ARCCSR}/${AUTH_TYPE_ARC}/${AUTH_TYPE_BOOTSTRAP} (required)"
    echo "  -e <existing node name> (required):"
    echo "      specify the existing node to copy /etc/kubernetes/azure.json from. Ideally this is a cloud node so we have good connectivity."
    echo "      ${AUTH_TYPE_ARCCSR}: use the arc AAD MSI to request the server signs a cert, then use the cert to act as a node. "
    echo "              Usually the case with AAD RBAC."
    echo "      ${AUTH_TYPE_ARC}: use the arc AAD MSI to act as a node directly. Usually the case with AAD Auth and K8s RBAC."
    echo "      ${AUTH_TYPE_AZURECSR}: use the azure AAD MSI to request the server signs a cert, then use the cert to act as a node. "
    echo "              Usually the case with AAD RBAC."
    echo "      ${AUTH_TYPE_AZURE}: use the azure AAD MSI to act as a node directly. Usually the case with AAD Auth and K8s RBAC."
    echo "      ${AUTH_TYPE_BOOTSTRAP}: use a bootstrap token to request the server signs a cert, then use the cert to act as a node."
    echo "             Usually the case where the node is not joined to Arc or the cluster is not using AAD."
    echo "  -d <type>: if present, the script will be configured for the distribution you specify."
    echo "      ${DOWNLOAD_MODE_NONE}: (default) Do not install software, use sensible defaults"
    echo "      ${DOWNLOAD_MODE_DIRECT}: Download directly from source repositories, use sensible defaults"
    echo "      ${DOWNLOAD_MODE_UBUNTU}: Use \"yum\" to download and install software and configure for Ubuntu"
    echo "      ${DOWNLOAD_MODE_MARINER}: Use \"yum\" to download and install software and configure for Mariner"
    echo "  -n <node pool name>: specify the node pool. Default is $NODE_POOL"
    echo "  -s Make this node a system node. Default is user node"
    echo "  -r <runc version>: specify the version of runc. Default is $RUNC_VERSION"
    echo "  -c <containerd version>: specify the version of containerd. Default is $CONTAINERD_VERSION"
}

if [ "$#" -eq 0 ]; then
    helpFunction
    exit -1;
fi


while getopts "hi:a:d:n:r:c:e:s" OPTION
do 
   case $OPTION in
    s)
        NODE_MODE="system"
        ;;

    d) 
        DOWNLOAD_MODE=$OPTARG
        ;;

    n) 
        NODE_POOL=$OPTARG
        ;;

    h)
        # if -h, print help function and exit
        helpFunction
        exit 0
        ;;
    i)
        # -i requires an argument (because of ":" in the definition) so:
        AKS_RESOURCE_ID=$OPTARG
        ;;
    a)
        # -a requires an argument 
        AUTH_TYPE=$OPTARG
        ;;
    r)
        # -r requires an argument
        RUNC_VERSION=$OPTARG
        ;;
    c)
        # -c requires an argument
        CONTAINERD_VERSION=$OPTARG
        ;;
    e)
        # -e requires an argument
        EXISTING_NODE=$OPTARG
        ;;
    ?)
        echo "ERROR: unknown option"
        helpFunction
        exit -1
        ;;
    esac
done

if [[ -z "$AKS_RESOURCE_ID" ]]; then
   echo "Missing Cluster ID (-i) parameter"
   helpFunction
   exit -1
fi

if [[ -z "$AUTH_TYPE" ]]; then
   echo "Missing auth type (-a) parameter"
   helpFunction
   exit -1
fi

if [[ -z "$EXISTING_NODE" ]]; then
   echo "Missing existing node (-e) parameter"
   helpFunction
   exit -1
fi

case "$AUTH_TYPE" in
    $AUTH_TYPE_AZURE)
        ;;

    $AUTH_TYPE_AZURECSR)
        ;;

    $AUTH_TYPE_ARC)
        ;;

    $AUTH_TYPE_ARCCSR)
        ;;

    $AUTH_TYPE_BOOTSTRAP)
        ;;

    *)
    echo "Invalid auth type (-a) parameter: $AUTH_TYPE"
    helpFunction
    exit -1
    ;;
esac

case "$DOWNLOAD_MODE" in
    $DOWNLOAD_MODE_DIRECT)
        ;;

    $DOWNLOAD_MODE_NONE)
       ;;

    $DOWNLOAD_MODE_MARINER)
        SYSTEMD_DIRECTORY=/usr/lib/systemd/system
        ;;

    $DOWNLOAD_MODE_UBUNTU)
        SYSTEMD_DIRECTORY=/usr/lib/systemd/system
        RUNC_PATH=/usr/sbin/runc
        ;;

    *)
      echo "Invalid download mode (-d) parameter: $AUTH_TYPE"
      helpFunction
      exit -1
      ;;
esac

logValue "AKS_AAD_SERVER_ID" $AKS_AAD_SERVER_ID
logValue "NODE POOL" $NODE_POOL

CLUSTER_RESOURCE_DATA=$(az resource show --id $AKS_RESOURCE_ID)
if [ $? -ne 0 ]; then 
  echo "unable to get cluster resource data"
  exit 255
fi

getField() {
    local DATA=$1
    local JQPATH=$2
    local DESCRIPTION=$3

    local VALUE="$(echo $DATA | jq $JQPATH -r)"
    if [ $? -ne 0 ]; then 
        echo "unable to get $DESCRIPTION - command failed"
        exit 255
    fi
    if [ "$VALUE" == "" ]; then 
        echo "unable to get $DESCRIPTION - empty response"
        exit 255
    fi
    if [ "$VALUE" == "null" ]; then 
        echo "unable to get $DESCRIPTION - null response"
        exit 255
    fi

    echo $VALUE
    return 0
}

CLUSTER_RESOURCE_GROUP="$(getField "$CLUSTER_RESOURCE_DATA" ".resourceGroup" "Cluster Resource Group")"
logValue "CLUSTER_RESOURCE_GROUP" $CLUSTER_RESOURCE_GROUP

CLUSTER_NAME="$(getField "$CLUSTER_RESOURCE_DATA" ".name" "Cluster Resource Group")"
logValue "CLUSTER_NAME" $CLUSTER_NAME

NODE_RESOURCE_GROUP="$(getField "$CLUSTER_RESOURCE_DATA" ".properties.nodeResourceGroup" "Node Resource Group")"
NODE_RESOURCE_GROUP="${NODE_RESOURCE_GROUP:0:62}"
logValue "NODE_RESOURCE_GROUP" $NODE_RESOURCE_GROUP

SUBSCRIPTION="$(echo $AKS_RESOURCE_ID | cut -d "/" -f 3 )"
if [ $? -ne 0 ]; then 
  echo "unable to get subscription"
  exit 255
fi
logValue "SUBSCRIPTION"  $SUBSCRIPTION

AKS_PRINCIPAL="$(getField "$CLUSTER_RESOURCE_DATA" ".identity.principalId" "AKS Principal")"
logValue "AKS_PRINCIPAL" $AKS_PRINCIPAL

CLUSTER_DNS="$(getField "$CLUSTER_RESOURCE_DATA" ".properties.networkProfile.dnsServiceIP" "Cluster DNS")"
logValue "CLUSTER_DNS" $CLUSTER_DNS
logValue "NODE_MODE" $NODE_MODE
logValue "DOWNLOAD_MODE" $DOWNLOAD_MODE

# where you have access to the cluster directly

KUBE_CA=$(az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}" -f - | yq -r '.clusters[0].cluster."certificate-authority-data"' )
if [ $? -ne 0 ]; then 
  echo "unable to get kube cert (command failed)"
  exit 255
fi

if [ $KUBE_CA == "null" ]; then 
  echo "unable to get kube cert (command returned null)"
  exit 255
fi

if [ -z "$KUBE_CA" ]; then 
  echo "unable to get kube cert (cert empty)"
  exit 255
fi
logValue "KUBE_CA" ${KUBE_CA:0:20}...

KUBE_FQDN="$(getField "$CLUSTER_RESOURCE_DATA" ".properties.fqdn" "Kube FQDN")"
logValue "KUBE_FQDN" $KUBE_FQDN
KUBE_FQDN_FULL="https://${KUBE_FQDN}"


KUBE_VERSION="$(getField "$CLUSTER_RESOURCE_DATA" ".properties.currentKubernetesVersion" "Kube Version")"
logValue "KUBE_VERSION" $KUBE_VERSION

readarray -d "." -t VERSION_ARRAY <<< "$KUBE_VERSION"
KUBE_VERSION_MAJOR_MINOR="${VERSION_ARRAY[0]}.${VERSION_ARRAY[1]}"

logValue "KUBE_VERSION_MAJOR_MINOR" $KUBE_VERSION_MAJOR_MINOR

OUTPUT_FILE=bootstrap-${CLUSTER_NAME}--${CLUSTER_RESOURCE_GROUP}--${AUTH_TYPE}.sh
logValue "OUTPUT_FILE" "$OUTPUT_FILE"

echo

cat > $OUTPUT_FILE <<EOFEOFEOF
#!/usr/bin/env bash

logValue() {
    local NAME=\$1
    local VALUE=\$2

    printf "%25s: %s\n" "\$NAME" "\$VALUE"
}

logProgress() {
    echo "\$1"
}

logProgress2() {
    echo "  - \$1"
}

logProgress "Stopping kubelet if exists"
systemctl stop kubelet
systemctl disable kubelet

set -e

NODE_NAME=\$(hostname)
logValue "NODE_NAME" \$NODE_NAME
logProgress "Linking resolv.conf"
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

logProgress "Creating Directories"
mkdir -p /var/lib/cni
mkdir -p /opt/cni/bin
mkdir -p /etc/cni/net.d
mkdir -p /etc/kubernetes/volumeplugins
mkdir -p /etc/kubernetes/certs
mkdir -p /etc/kubernetes/manifests
mkdir -p /etc/containerd
mkdir -p ${SYSTEMD_DIRECTORY}/kubelet.service.d
mkdir -p /var/lib/kubelet

EOFEOFEOF

downloadKubernetesFromAcr() {

      cat >> $OUTPUT_FILE <<EOFEOFEOF

CPU_ARCH=\$(uname -m)
if [ "\$CPU_ARCH" == "x86_64" ]; then
  CPU_ARCH="amd64"
fi
logValue "CPU_ARCH" "\${CPU_ARCH}"

logProgress "Installing kubernetes componentary from ACR"

KUBENETES_URL="https://dl.k8s.io/v$KUBE_VERSION/kubernetes-node-linux-\${CPU_ARCH}.tar.gz"
logValue "KUBENETES_URL" "\${KUBENETES_URL}"

curl -LO \${KUBENETES_URL} || wget \${KUBENETES_URL}
tar -xvzf kubernetes-node-linux-\${CPU_ARCH}.tar.gz kubernetes/node/bin/{kubelet,kubectl,kubeadm}
mv kubernetes/node/bin/{kubelet,kubectl,kubeadm} "${KUBELET_LOCATION}"
rm -r kubernetes
rm kubernetes-node-linux-\${CPU_ARCH}.tar.gz

EOFEOFEOF

}

downloadDirect() {
    # https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-using-native-package-management

    logProgress "Adding downloads to install software:"
    logProgress2 "jq"
    logProgress2 "cni-plugins"
    logProgress2 "runc"
    logProgress2 "containerd"
    cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Installing jq"
apt install jq -y || yum install jq

logProgress "Downloading and installing runc"
curl -o runc -L https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
install -m 0555 runc "${RUNC_PATH}"
rm runc

logProgress "Downloading and installing containerd"
curl -LO https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
tar -xvzf containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz -C /usr
rm containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
EOFEOFEOF
}

downloadYum() {
    logProgress "Installing from yum:"
    logProgress2 "jq"
    logProgress2 "moby-runc"
    logProgress2 "moby-containerd"
    cat >> $OUTPUT_FILE <<EOFEOFEOF
logProgress "Installing:"
logProgress2 "jq"
logProgress2 "moby-runc"
logProgress2 "moby-containerd"

yum install -y jq
yum install -y moby-runc
yum install -y moby-containerd

EOFEOFEOF
}

downloadApt() {
    # https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-using-native-package-management

    logProgress "Adding downloads to install software:"
    logProgress2 "kubelet"
    logProgress2 "jq"
    logProgress2 "moby-runc"
    logProgress2 "moby-containerd"

    cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Configuring repositories"

UBUNTU_CODENAME=\$(lsb_release -c -s)
UBUNTU_RELEASE=\$(lsb_release -r -s)
DISTRO=\$( lsb_release -i -s | tr '[:upper:]' '[:lower:]' )

logValue "UBUNTU_CODENAME" "\${UBUNTU_CODENAME}"
logValue "UBUNTU_RELEASE" "\${UBUNTU_RELEASE}"
logValue "DISTRO" "\${DISTRO}"

DEB_URL="https://packages.microsoft.com/config/\${DISTRO}/\${UBUNTU_RELEASE}/packages-microsoft-prod.deb"
logValue "DEB_URL" "\${DEB_URL}"

curl -LO \$DEB_URL || wget \$DEB_URL
dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb

logProgress "Installing"
logProgress2 "jq"
logProgress2 "moby-runc"
logProgress2 "moby-containerd"

apt-get update
apt-get install -y jq
apt-get install -y moby-runc
apt-get install -y moby-containerd

logProgress "Disabling containerd service - will be enabled after configuration"
systemctl disable --now containerd

EOFEOFEOF
}

case "$DOWNLOAD_MODE" in
    $DOWNLOAD_MODE_NONE)
      ;;

    $DOWNLOAD_MODE_DIRECT)
      downloadDirect
      downloadKubernetesFromAcr
      ;;

    $DOWNLOAD_MODE_MARINER)
      downloadYum
      downloadKubernetesFromAcr
     ;;

    $DOWNLOAD_MODE_UBUNTU)
      downloadApt
      downloadKubernetesFromAcr
      ;;
esac



logProgress "Adding standard files:"
logProgress2 "${SYSTEMD_DIRECTORY}/containerd.service"
logProgress2 "/etc/containerd/config.toml"
logProgress2 "/etc/containerd/kubenet_template.conf"
logProgress2 "/etc/sysctl.d/999-sysctl-aks.conf"
logProgress2 "/etc/default/kubelet"
logProgress2 "${SYSTEMD_DIRECTORY}/kubelet.service.d/10-containerd.conf"
logProgress2 "${SYSTEMD_DIRECTORY}/kubelet.service"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/containerd.service"

tee ${SYSTEMD_DIRECTORY}/containerd.service > /dev/null <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target
[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999
[Install]
WantedBy=multi-user.target
EOF

logProgress "Creating /etc/containerd/config.toml"

tee /etc/containerd/config.toml > /dev/null <<EOF
version = 2
oom_score = 0
[plugins."io.containerd.grpc.v1.cri"]
	sandbox_image = "mcr.microsoft.com/oss/kubernetes/pause:3.6"
	[plugins."io.containerd.grpc.v1.cri".containerd]
		default_runtime_name = "runc"
		[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
			runtime_type = "io.containerd.runc.v2"
		[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
			BinaryName = "${RUNC_PATH}"
			SystemdCgroup = true
		[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.untrusted]
			runtime_type = "io.containerd.runc.v2"
		[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.untrusted.options]
			BinaryName = "${RUNC_PATH}"
	[plugins."io.containerd.grpc.v1.cri".cni]
		bin_dir = "/opt/cni/bin"
		conf_dir = "/etc/cni/net.d"
		conf_template = "/etc/containerd/kubenet_template.conf"
	[plugins."io.containerd.grpc.v1.cri".registry]
		config_path = "/etc/containerd/certs.d"
	[plugins."io.containerd.grpc.v1.cri".registry.headers]
		X-Meta-Source-Client = ["azure/aks"]
[metrics]
	address = "0.0.0.0:10257"
EOF

logProgress "Creating /etc/containerd/kubenet_template.conf"

# for kubenet
tee /etc/containerd/kubenet_template.conf > /dev/null <<'EOF'
{
    "cniVersion": "0.3.1",
    "name": "kubenet",
    "plugins": [{
    "type": "bridge",
    "bridge": "cbr0",
    "mtu": 1500,
    "addIf": "eth0",
    "isGateway": true,
    "ipMasq": false,
    "promiscMode": true,
    "hairpinMode": false,
    "ipam": {
        "type": "host-local",
        "ranges": [{{range \$i, \$range := .PodCIDRRanges}}{{if \$i}}, {{end}}[{"subnet": "{{\$range}}"}]{{end}}],
        "routes": [{{range \$i, \$route := .Routes}}{{if \$i}}, {{end}}{"dst": "{{\$route}}"}{{end}}]
    }
    },
    {
    "type": "portmap",
    "capabilities": {"portMappings": true},
    "externalSetMarkChain": "KUBE-MARK-MASQ"
    }]
}
EOF

logProgress "Creating /etc/sysctl.d/999-sysctl-aks.conf"

tee /etc/sysctl.d/999-sysctl-aks.conf > /dev/null <<EOF
# container networking
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1

# refer to https://github.com/kubernetes/kubernetes/blob/75d45bdfc9eeda15fb550e00da662c12d7d37985/pkg/kubelet/cm/container_manager_linux.go#L359-L397
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
# to ensure node stability, we set this to the PID_MAX_LIMIT on 64-bit systems: refer to https://kubernetes.io/docs/concepts/policy/pid-limiting/
kernel.pid_max = 4194304
# https://github.com/Azure/AKS/issues/772
fs.inotify.max_user_watches = 1048576
# Ubuntu 22.04 has inotify_max_user_instances set to 128, where as Ubuntu 18.04 had 1024. 
fs.inotify.max_user_instances = 1024

# This is a partial workaround to this upstream Kubernetes issue:
# https://github.com/kubernetes/kubernetes/issues/41916#issuecomment-312428731
net.ipv4.tcp_retries2=8
net.core.message_burst=80
net.core.message_cost=40
net.core.somaxconn=16384
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
EOF


logProgress "Creating /etc/default/kubelet"

# adust flags as desired
tee /etc/default/kubelet > /dev/null <<EOF
KUBELET_NODE_LABELS="\\
kubernetes.azure.com/cluster=${NODE_RESOURCE_GROUP},\\
kubernetes.azure.com/agentpool=${NODE_POOL},\\
kubernetes.azure.com/mode=${NODE_MODE},\\
kubernetes.azure.com/role=agent,\\
node.kubernetes.io/exclude-from-external-load-balancers=true,\\
kubernetes.azure.com/managed=false,\\
kubernetes.azure.com/stretch=true\\
"
KUBELET_FLAGS="\\
  --address=0.0.0.0 \\
  --anonymous-auth=false \\
  --authentication-token-webhook=true \\
  --authorization-mode=Webhook \\
  --cgroup-driver=systemd \\
  --cgroups-per-qos=true \\
  --client-ca-file=/etc/kubernetes/certs/ca.crt \\
  --cluster-dns=${CLUSTER_DNS} \\
  --cluster-domain=cluster.local \\
  --enforce-node-allocatable=pods \\
  --event-qps=0  \\
  --eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%  \\
  --kube-reserved=cpu=100m,memory=200Mi  \\
  --image-gc-high-threshold=85  \\
  --image-gc-low-threshold=80  \\
  --max-pods=110  \\
  --node-status-update-frequency=10s  \\
  --pod-max-pids=-1  \\
  --protect-kernel-defaults=true  \\
  --read-only-port=0  \\
  --resolv-conf=/run/systemd/resolve/resolv.conf  \\
  --streaming-connection-idle-timeout=4h  \\
  --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_128_GCM_SHA256 \\
  "
EOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-containerd.conf"

# can simplify this + 2 following files by merging together
tee ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-containerd.conf > /dev/null <<'EOF'
[Service]
Environment=KUBELET_CONTAINERD_FLAGS="--runtime-request-timeout=15m --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/kubelet.service"

tee ${SYSTEMD_DIRECTORY}/kubelet.service > /dev/null <<'EOF'
[Unit]
Description=Kubelet
ConditionPathExists=$KUBELET_LOCATION/kubelet
[Service]
Restart=always
EnvironmentFile=/etc/default/kubelet
SuccessExitStatus=143
# Ace does not recall why this is done
ExecStartPre=/bin/bash -c "if [ \$(mount | grep \"/var/lib/kubelet\" | wc -l) -le 0 ] ; then /bin/mount --bind /var/lib/kubelet /var/lib/kubelet ; fi"
ExecStartPre=/bin/mount --make-shared /var/lib/kubelet
ExecStartPre=-/sbin/ebtables -t nat --list
ExecStartPre=-/sbin/iptables -t nat --numeric --list
ExecStart=$KUBELET_LOCATION/kubelet \\
        --enable-server \\
        --node-labels="\${KUBELET_NODE_LABELS}" \\
        --v=2 \\
        --volume-plugin-dir=/etc/kubernetes/volumeplugins \\
        --pod-manifest-path=/etc/kubernetes/manifests/ \\
        \$KUBELET_TLS_BOOTSTRAP_FLAGS \\
        \$KUBELET_CONFIG_FILE_FLAGS \\
        \$KUBELET_CONTAINERD_FLAGS \\
        \$KUBELET_FLAGS 
[Install]
WantedBy=multi-user.target
EOF

EOFEOFEOF

addAzureTokenLookup() {
logProgress "Creating /var/lib/kubelet/token.sh"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating /var/lib/kubelet/token.sh"

tee /var/lib/kubelet/token.sh >/dev/null <<'EOF'
#!/bin/bash

TOKEN_URL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$AKS_AAD_SERVER_ID"
EXECCREDENTIAL='''
{
  "kind": "ExecCredential",
  "apiVersion": "client.authentication.k8s.io/v1beta1",
  "spec": {
    "interactive": false
  },
  "status": {
    "expirationTimestamp": .expires_on | tonumber | todate,
    "token": .access_token
  }
}
'''

curl -s -H Metadata:true \$TOKEN_URL | jq "\$EXECCREDENTIAL"
EOF
chmod 755 /var/lib/kubelet/token.sh

EOFEOFEOF

}



addArcTokenLookup() {
logProgress "Creating /var/lib/kubelet/token.sh"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating /var/lib/kubelet/token.sh"

tee /var/lib/kubelet/token.sh >/dev/null <<'EOF'
#!/bin/bash

# Fetch an AAD token from Azure Arc HIMDS and output it in the ExecCredential format
# https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication

TOKEN_URL="http://127.0.0.1:40342/metadata/identity/oauth2/token?api-version=2019-11-01&resource=$AKS_AAD_SERVER_ID"
EXECCREDENTIAL='''
{
  "kind": "ExecCredential",
  "apiVersion": "client.authentication.k8s.io/v1beta1",
  "spec": {
    "interactive": false
  },
  "status": {
    "expirationTimestamp": .expires_on | tonumber | todate,
    "token": .access_token
  }
}
'''

# Arc IMDS requires a challenge token from a file only readable by root for security
CHALLENGE_TOKEN_PATH=\$(curl -s -D - -H Metadata:true \$TOKEN_URL | grep Www-Authenticate | cut -d "=" -f 2 | tr -d "[:cntrl:]")
CHALLENGE_TOKEN=\$(cat \$CHALLENGE_TOKEN_PATH)
if [ $? -ne 0 ]; then
    echo "Could not retrieve challenge token, double check that this command is run with root privileges."
    exit 255
fi

curl -s -H Metadata:true -H "Authorization: Basic \$CHALLENGE_TOKEN" \$TOKEN_URL | jq "\$EXECCREDENTIAL"
EOF
chmod 755 /var/lib/kubelet/token.sh

EOFEOFEOF

}

addKubeletActAsNode() {
logProgress "Creating files to act directly as a node"
logProgress2 "${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"
logProgress2 "/var/lib/kubelet/kubeconfig"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"

tee ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf > /dev/null <<'EOF'
[Service]
Environment=KUBELET_TLS_BOOTSTRAP_FLAGS="--kubeconfig /var/lib/kubelet/kubeconfig"
EOF

logProgress "Creating /var/lib/kubelet/kubeconfig"

tee /var/lib/kubelet/kubeconfig > /dev/null <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/certs/ca.crt
    server: $KUBE_FQDN_FULL
  name: default-cluster
contexts:
- context:
    cluster: default-cluster
    namespace: default
    user: default-auth
  name: default-context
current-context: default-context
kind: Config
preferences: {}
users:
- name: default-auth
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: /var/lib/kubelet/token.sh
      env: null
      provideClusterInfo: false
EOF

EOFEOFEOF
}

addKubletBootstrapGenerateCsr() {
  logProgress "Creating files to create CSR"
  logProgress2 "${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"
  logProgress2 "/var/lib/kubelet/bootstrap-kubeconfig"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"

tee ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf > /dev/null <<'EOF'
[Service]
Environment=KUBELET_TLS_BOOTSTRAP_FLAGS="--kubeconfig /var/lib/kubelet/kubeconfig --bootstrap-kubeconfig /var/lib/kubelet/bootstrap-kubeconfig"
EOF

logProgress "Creating /var/lib/kubelet/bootstrap-kubeconfig"

tee /var/lib/kubelet/bootstrap-kubeconfig > /dev/null <<EOF
apiVersion: v1
kind: Config
clusters:
- name: localcluster
  cluster:
    certificate-authority: /etc/kubernetes/certs/ca.crt
    server: "$KUBE_FQDN_FULL"
users:
- name: kubelet-bootstrap
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: /var/lib/kubelet/token.sh
      env: null
      provideClusterInfo: false
contexts:
- context:
    cluster: localcluster
    user: kubelet-bootstrap
  name: bootstrap-context
current-context: bootstrap-context
EOF

EOFEOFEOF

}

addBootstrapToken() {

    logProgress "Creating bootstrap token"
    local AKS_TOKEN=""
    local TOOLS_VERSION=$KUBE_VERSION
    KCFG=$(az aks get-credentials --subscription "${SUBSCRIPTION}" --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" -f -)

    INSTALL_KUBEADM="
    mkdir /home/nonroot/.kube; 
    echo \"${KCFG}\" > /home/nonroot/.kube/config; 

    curl --silent -L --remote-name-all https://dl.k8s.io/release/v${TOOLS_VERSION}/bin/linux/amd64/kubeadm -o /home/nonroot/kubeadm; 
    chmod +x /home/nonroot/kubeadm"


    AKS_TOKEN=$(az aks command invoke \
        --subscription "${SUBSCRIPTION}" \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${CLUSTER_NAME}" \
        --command "$INSTALL_KUBEADM; /home/nonroot/kubeadm token create --one-output --skip-headers --skip-log-headers --v=0 --ttl 3600s;" \
        --output "json" | jq -r ".logs" | tail -n 2)

    if [ $? -ne 0 ]; then 
        echo "unable to get bootstrap token (command failed)"
        exit 255
    fi
    if [ -z $AKS_TOKEN ]; then 
        echo "unable to get bootstrap token (token empty)"
        exit 255
    fi

  logProgress "Creating files to create CSR via bootstrap token"
  logProgress2 "${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"
  logProgress2 "/var/lib/kubelet/bootstrap-kubeconfig"

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf"

tee ${SYSTEMD_DIRECTORY}/kubelet.service.d/10-tlsbootstrap.conf > /dev/null <<'EOF'
[Service]
Environment=KUBELET_TLS_BOOTSTRAP_FLAGS="--kubeconfig /var/lib/kubelet/kubeconfig --bootstrap-kubeconfig /var/lib/kubelet/bootstrap-kubeconfig"
EOF

logProgress "Creating /var/lib/kubelet/bootstrap-kubeconfig"

tee /var/lib/kubelet/bootstrap-kubeconfig > /dev/null <<EOF
apiVersion: v1
kind: Config
clusters:
- name: localcluster
  cluster:
    certificate-authority: /etc/kubernetes/certs/ca.crt
    server: "$KUBE_FQDN_FULL"
users:
- name: kubelet-bootstrap
  user:
    token: "$AKS_TOKEN"
contexts:
- context:
    cluster: localcluster
    user: kubelet-bootstrap
  name: bootstrap-context
current-context: bootstrap-context
EOF

EOFEOFEOF

}

case "$AUTH_TYPE" in
     $AUTH_TYPE_AZURE)
        addAzureTokenLookup
        addKubeletActAsNode
       ;;

    $AUTH_TYPE_AZURECSR)
        addAzureTokenLookup
        addKubletBootstrapGenerateCsr
        ;;

   $AUTH_TYPE_ARC)
        addArcTokenLookup
        addKubeletActAsNode
        ;;

    $AUTH_TYPE_ARCCSR)
        addArcTokenLookup
        addKubletBootstrapGenerateCsr
        ;;

    $AUTH_TYPE_BOOTSTRAP)
        addBootstrapToken
        ;;
esac


logProgress "Finalising script"
logProgress2 "/etc/kubernetes/certs/ca.crt"
logProgress2 "/etc/kubernetes/azure.json"

# TODO: we probably want to render this file instead in future.
VMSS_DATA=$(az vmss list -g $NODE_RESOURCE_GROUP)
NEW_VMSS_NAME=$(echo $VMSS_DATA | jq '.[] | select(.tags."aks-managed-poolName"=="'$NODE_POOL'") | .name')
AZURE_JSON=$(kubectl node-shell $EXISTING_NODE -- cat /etc/kubernetes/azure.json)
OLD_VMSS_NAME=$(echo "$AZURE_JSON" | jq '.primaryScaleSetName')
NEW_AZURE_JSON=$(echo "$AZURE_JSON" | sed -e 's/'$OLD_VMSS_NAME'/'$NEW_VMSS_NAME'/')

cat >> $OUTPUT_FILE <<EOFEOFEOF

logProgress "Creating /etc/kubernetes/certs/ca.crt"

KUBE_CA_PATH="/etc/kubernetes/certs/ca.crt"
touch "\${KUBE_CA_PATH}"
chmod 0600 "\${KUBE_CA_PATH}"
chown root:root "\${KUBE_CA_PATH}"
echo '$KUBE_CA' | base64 -d > /etc/kubernetes/certs/ca.crt

logProgress "Creating /etc/kubernetes/azure.json"

AZURE_JSON_PATH="/etc/kubernetes/azure.json"
touch "\${AZURE_JSON_PATH}"
chmod 0600 "\${AZURE_JSON_PATH}"
chown root:root "\${AZURE_JSON_PATH}"
echo '$NEW_AZURE_JSON' > "\${AZURE_JSON_PATH}"

logProgress "Enabling containerd and kubelet serfvices"

sysctl --system
systemctl enable --now containerd
systemctl enable --now kubelet

# sanity check? might be uninitialized at this point
# timeout 30s grep -q 'NodeReady' <(journalctl -u kubelet -f --no-tail)

echo
echo
echo The node has now been configured and both containerd and kubelet have been started. Sometimes the node needs rebooting after configuration, and
echo sometimes it needs draining of pods. To do a drain, run these two commands to drain all pods then make the node ready for the pods again.
echo \* kubectl drain \$NODE_NAME  --force --ignore-daemonsets --delete-emptydir-data
echo \* kubectl uncordon \$NODE_NAME
EOFEOFEOF

echo
echo "Copy the output file to your Arc-joined nodes and run it to install kubernetes and join the cluster."
