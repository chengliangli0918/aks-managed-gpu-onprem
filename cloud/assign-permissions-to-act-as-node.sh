#!/bin/bash

AUTH_TYPE_ARC="arc"
AUTH_TYPE_ARCCSR="arccsr"
AUTH_TYPE_AZURE="azure"
AUTH_TYPE_AZURECSR="azurecsr"
AAD_GROUP_TO_CREATE_CSR="AKS Certificate Signing Requests"

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
    echo "  -i <ARM resource id for Cluster> (required)"
    echo "  -m <ARM resource id for Arc Machine or VM> (required)"
    echo "  -a node join (required)"
    echo "      ${AUTH_TYPE_ARCCSR}/${AUTH_TYPE_AZURECSR}: put the machine MSI into the AAD group $AAD_GROUP_TO_CREATE_CSR so it can create a CSR. This is the typical option when the cluster is using AAD RBAC."
    echo "      ${AUTH_TYPE_ARC}/${AUTH_TYPE_AZURE}: use kubectl to assign permissions for the machine MSI to act as a node directly. This is the typical option when the cluster is using K8s RBAC."
    echo "  -r AAD/Entra role to assign permissions (default is '$AAD_GROUP_TO_CREATE_CSR', optional)"
}

if [ "$#" -eq 0 ]; then
    helpFunction
    exit -1;
fi

while getopts "hi:m:a:r:" OPTION
do 
   case $OPTION in
    h)
        # if -h, print help function and exit
        helpFunction
        exit 0
        ;;
    i)
        # -i requires an argument (because of ":" in the definition) so:
        AKS_RESOURCE_ID=$OPTARG
        ;;
     m)
       # -i requires an argument (because of ":" in the definition) so:
        NODE_RESOURCE_ID=$OPTARG
        ;;
     r)
       # -i requires an argument (because of ":" in the definition) so:
        AAD_GROUP_TO_CREATE_CSR=$OPTARG
        ;;
    a)
        # -a requires an argument 
        AUTH_TYPE=$OPTARG
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

if [[ -z "$NODE_RESOURCE_ID" ]]; then
   echo "Missing arm machine ID (-m) parameter"
   helpFunction
   exit -1
fi

if [[ -z "$AUTH_TYPE" ]]; then
   echo "Missing auth type (-a) parameter"
   helpFunction
   exit -1
fi

case "$AUTH_TYPE" in
    $AUTH_TYPE_ARC)
        ;;

    $AUTH_TYPE_ARCCSR)
        ;;

    $AUTH_TYPE_AZURE)
        ;;

    $AUTH_TYPE_AZURECSR)
        ;;

    *)
    echo "Invalid auth type (-a) parameter: $AUTH_TYPE"
    helpFunction
    exit -1
    ;;
esac

CLUSTER_RESOURCE_DATA=$(az resource show --id $AKS_RESOURCE_ID)
if [ $? -ne 0 ]; then 
  echo "unable to get cluster resource data"
  exit 255
fi

function getField {
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

SUBSCRIPTION="$(echo $AKS_RESOURCE_ID | cut -d "/" -f 3 )"
if [ $? -ne 0 ]; then 
  echo "unable to get subscription"
  exit 255
fi
logValue "SUBSCRIPTION" $SUBSCRIPTION

NODE_RESOURCE_DATA=$(az resource show --id $NODE_RESOURCE_ID)
if [ $? -ne 0 ]; then 
  echo "unable to get node resource data"
  exit 255
fi

NODE_PRINCIPAL="$(getField "$NODE_RESOURCE_DATA" ".identity.principalId" "Node Machine Principal ID")"
logValue "NODE_PRINCIPAL" $NODE_PRINCIPAL

NODE_NAME="$(getField "$NODE_RESOURCE_DATA" ".name" "Node Machine Name")"
logValue "NODE_NAME" $NODE_NAME

function grant_access_aad_rbac {
    logProgress "Granting access to $NODE_PRINCIPAL on $CLUSTER_NAME via AAD RBAC"
    logProgress "Adding $NODE_PRINCIPAL to group $AAD_GROUP_TO_CREATE_CSR with scope $AKS_RESOURCE_ID"

    az role assignment create --assignee "$NODE_PRINCIPAL" \
        --role "$AAD_GROUP_TO_CREATE_CSR" \
        --scope "$AKS_RESOURCE_ID"
}

function grant_access_k8s_rbac {
    logProgress "Granting access to $NODE_PRINCIPAL on $CLUSTER_NAME via K8S RBAC"
    az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${CLUSTER_RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

    kubectl get clusterrolebinding arc-nodes -o name > /dev/null
    if [ $? -eq 0 ]; then 
        logProgress "Patching cluster role binding"
        kubectl patch clusterrolebinding arc-nodes --type=json -p "[{\"op\":\"add\",\"path\":\"/subjects/-\",\"value\":{\"apiGroup\":\"rbac.authorization.k8s.io\",\"kind\":\"User\",\"name\":\"${NODE_PRINCIPAL}\"}}]"
    else 
        logProgress "Creating cluster role binding"
        kubectl create clusterrolebinding arc-nodes --clusterrole=system:node --user=$NODE_PRINCIPAL
    fi
    
    kubectl get configmap -n kube-system arc-node-names -o name > /dev/null
    if [ $? -eq 0 ]; then 
        logProgress "Patching configmap"
        kubectl patch configmap arc-node-names -n kube-system -p "{\"data\":{\"${NODE_PRINCIPAL}\":\"${NODE_NAME}\"}}"
    else
        logProgress "Creating configmap"
        kubectl create configmap -n kube-system arc-node-names --from-literal ${NODE_PRINCIPAL}=${NODE_NAME}
    fi;
}

case "$AUTH_TYPE" in
    $AUTH_TYPE_ARC)
        grant_access_k8s_rbac
        ;;

    $AUTH_TYPE_ARCCSR)
        grant_access_aad_rbac
      ;;

    $AUTH_TYPE_AZURE)
        grant_access_k8s_rbac
        ;;

    $AUTH_TYPE_AZURECSR)
        grant_access_aad_rbac
      ;;

esac
