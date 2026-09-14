helpFunction() {
    echo "Usage: "
    echo "  -a <acr name>: acr to attach to the cluster"
}

while getopts "ha:" OPTION
do 
   case $OPTION in
    a)
        ACR_NAME=$OPTARG
        ;;

    h)
        # if -h, print help function and exit
        helpFunction
        exit 0
        ;;

    ?)
        echo "ERROR: unknown option"
        helpFunction
        exit -1
        ;;
    esac
done

#if [[ -z "$AAD_ADMIN_ID" ]]; then
#    echo "The variable AAD_ADMIN_ID needs to be set"
#    exit
#fi

# Resource Group
echo "Creating resource group."
az group create \
    --subscription "${SUBSCRIPTION}" \
    --tags "owner=${USER}" \
    --location "${REGION}" \
    --resource-group "${RESOURCE_GROUP}"

# VNET
echo "Creating VNet."
az network vnet create \
    --tags "owner=${USER}" \
    --subscription "${SUBSCRIPTION}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VNET_ID}" \
    --address-prefixes "${VNET_CIDR}" \
    --subnet-name "${SUBNET_ID}" \
    --subnet-prefix "${NODE_SUBNET_CIDR}"

# Gateway Subnet
echo "Creating gateway subnet."
az network vnet subnet create \
    --name GatewaySubnet \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_ID}" \
    --address-prefixes "${GATEWAY_SUBNET_CIDR}" \
    --default-outbound 1 

# Point-Site Gateway Public IP
echo "Creating point-to-site gateway public IP."
az network public-ip create \
    --name P2SGatewayPublicIP \
    --resource-group "${RESOURCE_GROUP}" \
    --zone 1

# Virtual Network Gateway
echo "Creating VNet gateway. This will take about 25 minutes."
az network vnet-gateway create \
    --name Gateway \
    --location "${REGION}" \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet "${VNET_ID}" \
    --public-ip-addresses P2SGatewayPublicIP \
    --gateway-type Vpn \
    --sku VpnGw2AZ \
    --vpn-type RouteBased \
    --address-prefixes 172.16.201.0/24 \
    --client-protocol OpenVPN

# AKS Cluster
echo "Creating AKS cluster. This will take about 5 minutes."
az aks create \
    --subscription "${SUBSCRIPTION}" \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --tags "owner=${USER}" \
    --os-sku "Ubuntu" \
    --location "${REGION}" \
    --node-vm-size Standard_D4_v3 \
    --node-count 2 \
    --vnet-subnet-id "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_ID}/subnets/${SUBNET_ID}" \
    --service-cidr "${CLUSTER_SERVICE_CIDR}" \
    --dns-service-ip "${CLUSTER_DNS_SERVER}" \
    --vm-set-type "VirtualMachineScaleSets" \
    --network-plugin none \
    --pod-cidr ${POD_CIDR} \
    --enable-node-public-ip \
    --disable-disk-driver \
    --disable-file-driver \
    --ssh-key-value ~/.ssh/id_rsa.pub \
    --enable-managed-identity \
    --enable-aad \
    --enable-azure-rbac
    $(
        if [[ -n "${ACR_NAME}" ]]; then
            echo "--attach-acr ""${ACR_NAME}"
        fi
    )

# User nodepool
echo "Adding user nodepool to AKS cluster. This will take about a minute."
az aks nodepool add \
    --resource-group ${RESOURCE_GROUP} \
    --cluster-name ${CLUSTER_NAME} \
    --mode User \
    --name nodepool2 \
    --node-count 0

# AKS credentials
echo "Getting AKS credentials."
az aks get-credentials \
    --subscription "${SUBSCRIPTION}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --overwrite-existing


# Install Cilium as the CNI for the AKS BYOCNI cluster.
helm repo add cilium https://helm.cilium.io/ 
helm install cilium cilium/cilium --set aksbyocni.enabled=true --set nodeinit.enabled=true --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}"