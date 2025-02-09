#!/bin/bash

# Set Key Vault Name
KEYVAULT_NAME="<KEYVAULT NAME>"

# Fetch Connection Details From Key Vault
SQL_SERVER="<SERVER NAME>"
SQL_USER=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "<SECRET NAME>" --query "value" -o tsv)
SQL_PASSWORD=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "<SECRET NAME>" --query "value" -o tsv)
SQL_DB="<DATABASE NAME>"

# Azure Resource Details
RESOURCE_GROUP="<RESOURCE GROUP>"
VM_NAME="<VM NAME>"
ADF_NAME="<ADF NAME>"
ADF_PIPELINE_NAME="<PIPELINE NAME>"
SYNAPSE_WORKSPACE="<SYNAPSE WORKSPACE NAME>"
SYNAPSE_PIPELINE_NAME="<SYNAPSE PIPELINE NAME>"
APP_ID="<SERVICE PRINCIPAL CLIENT ID>"
APP_NAME="<SERVICE PRINCIPAL NAME>"
SP_PASSWORD=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "<SECRET NAME>" --query "value" -o tsv)
SP_ACCESS_TOKEN="<ACCESS TOKEN NAME>"
TENANT_ID="<TENANT ID>"
PUBLIC_IP="<IP NAME>"
NIC_NAME="<VM NIC NAME>"
DATABRICKS_WORKSPACE="<DATABRICKS WORKSPACE>"
SUB_ID="<SUBCRIPTION ID>"
CLUSTER_NAME="<DATABRICKS CLUSTER NAME"

# Login to Azure via Service Principal
az login --service-principal -u $APP_ID -p $SP_PASSWORD --tenant $TENANT_ID
az account set --subscription $SUB_ID

# Connect to VPN
osascript ./connect_vpn.scpt >> /dev/null
echo -e "\nConnecting to VPN..."
sleep 6

# Check VPN Connection
VPN_CONNECTION=$(ifconfig | grep -w "ipsec0")
if [ -z "$VPN_CONNECTION" ]; then
	echo "VPN not connected."
else 
	echo "VPN connected."
fi

# Query to get the List of All User Tables
TABLES=$(sqlcmd -S $SQL_SERVER -U $SQL_USER -P $SQL_PASSWORD -d $SQL_DB -h -1 -W -Q "
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE';
")

# Track Changes if Exists
CHANGES_DETECTED=0

IFS=$'\n'

# Loop Through Tables to Check for Changes
for TABLE in $TABLES; do
	# Skip Empty Tables or Headers
    	if [ -z "$TABLE" ] || [[ "$TABLE" == "TABLE_NAME" ]]; then
        	continue
    	fi
    
    	# Get the Change Count for Each Table
    	CHANGE_COUNT=$(sqlcmd -S $SQL_SERVER -U $SQL_USER -P $SQL_PASSWORD -d $SQL_DB -h -1 -W -Q "
    	SELECT COUNT(*) FROM CHANGETABLE(CHANGES "SalesLT.$TABLE", 0) AS CT;
    	")

    	COUNT=$(echo "$CHANGE_COUNT" | grep -E '^\d+$' | head -n 1)

    	echo -e "\nCount value: $COUNT"

    	if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        	echo -e "\nChanges detected in table $TABLE! Spinning up $VM_NAME, please standby..."
        	CHANGES_DETECTED="1"
		
		# Start Windows VM Where SHIR is Running
		az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME
        	
		# Wait Until the VM is in a Running State
        	while true; do
        		VM_STATUS=$(az vm get-instance-view --resource-group $RESOURCE_GROUP --name $VM_NAME --query "instanceView.statuses[?code=='PowerState/running'].code" -o tsv)
            		echo "VM Status: $VM_STATUS"
            		[ "$VM_STATUS" == "PowerState/running" ] && break || sleep 10
        	done
		
		# Check to See if VM Already Has a Public IP (If Not, Create One)
        	EXISTING_PUBLIC_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
        	if [ -z "$EXISTING_PUBLIC_IP" ]; then
        		az network public-ip create --resource-group $RESOURCE_GROUP --name $PUBLIC_IP --sku Basic --allocation-method Static
        	fi
        
		echo -e "\nCreating Public IP Address for $VM_NAME..."

        	while true; do
            		PUBLIC_IP_ADDR=$(az network public-ip show --resource-group $RESOURCE_GROUP --name $PUBLIC_IP --query "ipAddress" -o tsv)
            		[ -n "$PUBLIC_IP_ADDR" ] && break || sleep 5
        	done

		echo "$VM_NAME public IP: $PUBLIC_IP_ADDR"
		echo -e "\nAttaching Public IP to NIC..."
        
        	az network nic ip-config update --name ipconfig1 --nic-name $NIC_NAME --public-ip-address $PUBLIC_IP --resource-group $RESOURCE_GROUP

        	WINDOWS_PRIVATE_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].privateIPAddress" -o tsv)
        	echo "$VM_NAME Private IP: $WINDOWS_PRIVATE_IP"
        	sleep 4
		
		# Get Databricks Workspace URL
        	echo -e "\nCreating Databricks Compute Resource..."
        	DATABRICKS_URL=$(az databricks workspace show --resource-group $RESOURCE_GROUP --name $DATABRICKS_WORKSPACE --query "workspaceUrl" -o tsv)
        	echo -e "\nDatabricks URL: $DATABRICKS_URL"
		
		# Re-Authenticate into Azure with Service Principal
      		az login --service-principal -t $TENANT_ID -u $APP_ID -p $SP_PASSWORD
        	az account set --subscription $SUB_ID
        	
		# Acquire Access Token and Store it as a New Version in Key Vault (To Make Sure the Token Will Be Valid for Duration of Pipeline Run
        	ACCESS_TOKEN=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query "accessToken" -o tsv)
        	az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$SP_ACCESS_TOKEN" --value "$ACCESS_TOKEN" --output none
        	echo -e "\nUpdated Key Vault Secret Version: $SP_ACCESS_TOKEN"
        
		# Send API Request to Create Cluster in Databricks with the Service Principal
        	curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/create" \
        		-H "Authorization: Bearer $ACCESS_TOKEN" \
             		-H "Content-Type: application/json" \
             		-d @create-databricks-cluster.json
        
		# Get the List of Clusters Back to get Cluster ID
        	CLUSTER_ID=$(curl -X GET "https://$DATABRICKS_URL/api/2.0/clusters/list" \
        		-H "Authorization: Bearer $ACCESS_TOKEN" \
        		-H "Content-Type: application/json" | jq -r '.clusters[] | select(.cluster_name=="DataEngProj Cluster") | .cluster_id')
        
		# Periodically Check Status of Cluster Creation. Do Not Continue Until Cluster is in a Running State
        	while true; do
            		CLUSTER_STATE=$(curl -s -X GET "https://$DATABRICKS_URL/api/2.0/clusters/get?cluster_id=$CLUSTER_ID" \
            			-H "Authorization: Bearer $ACCESS_TOKEN" \
                        	-H "Content-Type: application/json" | jq -r '.state')
        		echo -e "\nCluster State: $CLUSTER_STATE"
            		[[ "$CLUSTER_STATE" == "RUNNING" ]] && break || sleep 60
        	done

		# Grant Service Principal permission to Attach Cluster to Notebooks and Delete Cluster once Done
		curl -s -X PUT "https://$DATABRICKS_URL/api/2.0/permissions/clusters/$CLUSTER_ID" \
    			-H "Authorization: Bearer $ACCESS_TOKEN" \
   			-H "Content-Type: application/json" \
    			-d '{
        			"access_control_list": [
					{
            					"service_principal_name": "'$APP_ID'",
            					"permission_level": "CAN_ATTACH_TO"
        				},
					{
						"service_principal_name": "'$APP_ID'",
						"permission_level": "CAN_MANAGE"
					}
				]
    		   	   }'

        	sleep 10

        	echo "Triggering Azure Data Factory Pipeline..."
        	ADF_RUN_ID=$(az datafactory pipeline create-run --resource-group "$RESOURCE_GROUP" --factory-name "$ADF_NAME" --pipeline-name "$ADF_PIPELINE_NAME" --parameters "{\"clusterId\":\"$CLUSTER_ID\"}" --query "runId" -o tsv)
        
        	MAX_RETRIES=45
			RETRY_COUNT=0

		# Check on Status of Pipeline Periodically
		while true; do
    			ADF_STATUS=$(az datafactory pipeline-run show --resource-group "$RESOURCE_GROUP" --factory-name "$ADF_NAME" --run-id "$ADF_RUN_ID" --query "status" -o tsv)
    			echo "ADF Pipeline Status: $ADF_STATUS"

    			if [[ "$ADF_STATUS" == "Succeeded" ]]; then
        			echo "ADF Pipeline completed successfully!"

				echo -e "\nTriggering Synapse Analytics Pipeline..."
				
				# If ADF Pipeline Succeeds, Trigger Synapse Pipeline
				SYNAPSE_RUN_ID=$(az synapse pipeline create-run \
					--workspace-name "$SYNAPSE_WORKSPACE" \
					--name "$SYNAPSE_PIPELINE_NAME" \
					--query "runId" -o tsv)

				MAX_RETRIES=20
				RETRY_COUNT=0

				# Periodically Check Status of the Pipeline Run
				while true; do
					SYNAPSE_STATUS=$(az synapse pipeline-run show \
						--workspace-name "$SYNAPSE_WORKSPACE" \
						--run-id "$SYNAPSE_RUN_ID" \
						--query "status" -o tsv)

				echo "Synapse Pipeline Status: $SYNAPSE_STATUS"

					if [[ "$SYNAPSE_STATUS" == "Succeeded" ]]; then
						echo -e "\nSynapse Pipeline completed successfully!"
						break
					elif [[ "$SYNAPSE_STATUS" == "Failed" || "$SYNAPSE_STATUS" == "Cancelled" ]]; then
						echo -e "\nError: Synapse Pipeline failed or was cancelled."
						break
					fi

					if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
						echo -e "\nError: Synapse Pipeline status check timed out."
						break
					fi

					((RETRY_COUNT++))
					sleep 5
				done

    			elif [[ "$ADF_STATUS" == "Failed" || "$ADF_STATUS" == "Cancelled" ]]; then
        			echo "Error: ADF Pipeline failed or was cancelled."
        			exit 1
    			fi

    			if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        			echo "Error: ADF Pipeline status check timed out."
        			exit 1
    			fi

    			((RETRY_COUNT++))
    			sleep 15
		done
		break
    	fi
done

echo -e "\nCleaning up Resources..."

# Delete Databricks Cluster to Save Cost
echo -e "\nDeleting Databricks cluster $CLUSTER_ID..."
	
curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/delete" \
	-H "Authorization: Bearer $ACCESS_TOKEN" \
	-H "Content-Type: application/json" \
	-d "{ \"cluster_id\": \"$CLUSTER_ID\" }"

curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/permanent-delete" \
	-H "Authorization: Bearer $ACCESS_TOKEN" \
	-H "Content-Type: application/json" \
	-d "{ \"cluster_id\": \"$CLUSTER_ID\" }"

# Verify Deletion of the Cluster
VERIFY_DELETE=$(curl -X GET "https://$DATABRICKS_URL/api/2.0/clusters/list" \
	-H "Authorization: Bearer $ACCESS_TOKEN" \
	-H "Content-Type: application/json" | jq -r '.clusters[]? | select(.cluster_id=="'$CLUSTER_ID'") | .cluster_id')

if [ -z "$VERIFY_DELETE" ]; then
	echo -e "\nCluster $CLUSTER_ID successfully deleted."
else
	echo -e "\nError: Cluster $CLUSTER_ID still exists."
	exit 1
fi

# Disassociate IP from NIC
az network nic ip-config update --resource-group $RESOURCE_GROUP --nic-name $NIC_NAME --name ipconfig1 --remove publicIpAddress --output none

# Delete Public IP Address
echo -e "\nDeleting IP: $PUBLIC_IP"
az network public-ip delete --resource-group $RESOURCE_GROUP --name $PUBLIC_IP --output none

# Check to see if IP exists still
EXISTING_PUBLIC_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].publicIPAddress.id" -o tsv)

if [ -z "$EXISTING_PUBLIC_IP" ]; then
	echo "Public IP $PUBLIC_IP successfully deleted."
else 
	echo "Error: Public IP $PUBLIC_IP still exists."
fi

# Stop and Deallocate Windows VM Running the SHIR 
az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME
echo -e "\n$VM_NAME is in Status: Stopped(deallocated)"

echo -e "\nCleanup Complete." 


osascript ./disconnect_vpn.scpt >> /dev/null
echo -e "\nVPN disconnected."
sleep 3
echo -e "\nScript completed."

