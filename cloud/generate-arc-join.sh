# The output script is taken from https://ms.portal.azure.com/#view/Microsoft_Azure_HybridCompute/ArcServerCreate.ReactView
subscriptionId="${SUBSCRIPTION}";
resourceGroup="${RESOURCE_GROUP}";
tenantId=$(az account show --subscription "${SUBSCRIPTION}" | jq -r '.tenantId');
location="${REGION}";
authType="token";
cloud="AzureCloud";
OUTPUT_FILE="arc-join.sh"

cat > "${OUTPUT_FILE}" << EOFEOFEOF

# Download the installation package
output=\$(wget https://gbl.his.arc.azure.com/azcmagent-linux -O /tmp/install_linux_azcmagent.sh 2>&1);
if [ \$? != 0 ]; then wget -qO- --method=PUT --body-data="{\"subscriptionId\":\"$subscriptionId\",\"resourceGroup\":\"$resourceGroup\",\"tenantId\":\"$tenantId\",\"location\":\"$location\",\"authType\":\"$authType\",\"operation\":\"onboarding\",\"messageType\":\"DownloadScriptFailed\",\"message\":\"$output\"}" "https://gbl.his.arc.azure.com/log" &> /dev/null || true; fi;
echo "\$output";

# Install the hybrid agent
bash /tmp/install_linux_azcmagent.sh;

# Run connect command
sudo azcmagent connect --resource-group "$resourceGroup" --tenant-id "$tenantId" --location "$location" --subscription-id "$subscriptionId" --cloud "$cloud" --tags "ArcSQLServerExtensionDeployment=Disabled";

EOFEOFEOF