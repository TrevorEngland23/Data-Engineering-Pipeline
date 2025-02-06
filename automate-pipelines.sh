#!/bin/bash

KEYVAULT_NAME="dataengprojkv1"

# Fetch Connection Details From Key Vault
SQL_SERVER="localhost"
SQL_USER=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "username" --query "value" -o tsv)
SQL_PASSWORD=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "sqlserverpassword" --query "value" -o tsv)
SQL_DB="AdventureWorksLT2022"

# Azure Resource Details
RESOURCE_GROUP="DataEngRG1"
VM_NAME="WindowsVM"
ADF_NAME="PipelineDFproj223"
ADF_PIPELINE_NAME="copy_all_tables_from_onprem"
SYNAPSE_WORKSPACE="dataengprojsynapse"
SYNAPSE_PIPELINE_NAME="DataEngSynapsePipeline"
APP_ID="cd1d83d1-1ef7-450c-8653-dcf7c02ceccf"
APP_NAME="Automation_Pipelines_SP"
SP_PASSWORD=$(az keyvault secret show --vault-name $KEYVAULT_NAME --name "service-principal-password" --query "value" -o tsv)
TENANT_ID="0a8877e6-76af-4741-9e59-de22e58d215a"
PUBLIC_IP="${VM_NAME}-pip1"
NIC_NAME="windowsvm306"
DATABRICKS_WORKSPACE="dataengprojDB"
SUB_ID="ade656e8-6c4a-456f-b489-7cc8d55c0a9c"
CLUSTER_NAME="DataEngProj Cluster"
VPN_NAME="Azure"

# Query to get the List of All User Tables
TABLES=$(sqlcmd -S $SQL_SERVER -U $SQL_USER -P $SQL_PASSWORD -d $SQL_DB -h -1 -W -Q "
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE';
")

az login --service-principal -u $APP_ID -p $SP_PASSWORD --tenant $TENANT_ID
az account set --subscription $SUB_ID

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

    echo "Count value: $COUNT"

    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "Changes detected in table $TABLE! Spinning up $VM_NAME, please standby..."
	    CHANGES_DETECTED="1"

        # Start Windows VM In Azure
        az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME

        # Wait for VM to be Running
	echo "Checking VM status..."

	while true; do
		VM_STATUS=$(az vm get-instance-view --resource-group $RESOURCE_GROUP --name $VM_NAME --query "instanceView.statuses[?code=='PowerState/running'].code" -o tsv)
		echo "Current Status of $VM_NAME: $VM_STATUS"

		if [ "$VM_STATUS" == "PowerState/running" ]; then
			echo "$VM_NAME is running! Continuing..."
			break
		fi 
		echo "Waiting for $VM_NAME to start..."
		sleep 10
	done

	# Create Public IP Address If Not Exists
	EXISTING_PUBLIC_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
	
	if [ -z "$EXISTING_PUBLIC_IP" ]; then
		echo "No public IP found for $VM_NAME. Creating new public IP address..."
		az network public-ip create --resource-group $RESOURCE_GROUP --name $PUBLIC_IP --sku Basic --allocation-method Static

		while true; do

			# Verify IP
			PUBLIC_IP_ADDR=$(az network public-ip show --resource-group $RESOURCE_GROUP --name $PUBLIC_IP --query "ipAddress" -o tsv)
			if [ -n "$PUBLIC_IP_ADDR" ]; then
				echo "Public IP $PUBLIC_IP_ADDR successfully created."
				break
			else
				echo "Waiting for Public IP creation..."
				sleep 5
			fi
		done

		# Attach IP to NIC
        	az network nic ip-config update --name ipconfig1 --nic-name $NIC_NAME --public-ip-address $PUBLIC_IP --resource-group $RESOURCE_GROUP

		# Only Continue Once IP Has Been Assigned
		while true; do
			# Get NIC's current public IP if exists
			ASSIGNED_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
		
			if [ -n "$ASSIGNED_IP" ]; then
				echo "Assignment Succeeded!"
				break
			else 
				echo "Waiting for Public IP to be assigned..."
				sleep 10
			fi
		done
	else

		echo "$VM_NAME public IP: $EXISTING_PUBLIC_IP"
	fi
	
	# Create Databricks Compute
	echo "Creating Databricks Compute Resource..."

	# Get Databricks Workspace URL
	DATABRICKS_URL=$(az databricks workspace show \
		--resource-group $RESOURCE_GROUP \
		--name $DATABRICKS_WORKSPACE \
		--query "workspaceUrl" -o tsv)

	echo "Databricks URL: https://$DATABRICKS_URL"

	# Retrieve OAuth Access Token for Service Principal to Authenticate
	ACCESS_TOKEN=$(az account get-access-token --resource https://$DATABRICKS_URL --query accessToken -o tsv)

	# Request to Create Databricks Cluster
	curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/create" \
		-H "Authorization: Bearer $ACCESS_TOKEN" \
		-H "Content-Type: application/json" \
		-d @create-databricks-cluster.json
	
	# Get the Cluster ID
	CLUSTER_ID=$(curl -X GET "https://$DATABRICKS_URL/api/2.0/clusters/list" \
		-H "Authorization: Bearer $ACCESS_TOKEN" \
		-H "Content-Type: application/json" | jq -r '.clusters[] | select(.cluster_name=="DataEngProj Cluster") | .cluster_id')

	echo "Cluster ID: $CLUSTER_ID"

	# Check Cluster State
	echo "Checking cluster state..."

	while true; do
		CLUSTER_STATE=$(curl -X GET "https://$DATABRICKS_URL/api/2.0/clusters/get?cluster_id=$CLUSTER_ID" \
			-H "Authorization: Bearer $ACCESS_TOKEN" \
			-H "Content-Type: application/json" | jq -r '.state')

		echo "Current Cluster State: $CLUSTER_STATE"

		if [[ "$CLUSTER_STATE" == "RUNNING" ]]; then
			echo "Databricks cluster is now running!"
			break
		fi

		echo "Cluster is still starting... checking again in 30 seconds."
		sleep 30
	done

        # Trigger ADF Pipeline
        echo "Triggering Azure Data Factory Pipeline..."
        ADF_RUN_ID=$(az datafactory pipeline create-run --resource-group $RESOURCE_GROUP --factory-name $ADF_NAME --pipeline-name $ADF_PIPELINE_NAME --query "runID" -o tsv)

        echo "Waiting for ADF Pipeline $ADF_RUN_ID to complete..."

        # Check ADF Pipeline Status
        while true; do
            ADF_STATUS=$(az datafactory pipeline-run show --resource-group $RESOURCE_GROUP --factory-name $ADF_NAME --run-id $ADF_RUN_ID --query "status" -o tsv)

            if [[ "$ADF_STATUS" == "Succeeded" ]]; then
                echo "ADF Pipeline completed successfully!"
                break
            elif [[ "$ADF_STATUS" == "Failed" ]]; then
                echo "ADF pipeline failing! Exiting..."
                exit 1
            else
                echo "ADF Pipeline still running... checking again in 30 seconds."
                sleep 30
            fi
        done

        # Trigger Synapse Analytics Pipeline
        SYNAPSE_RUN_ID=$(az synapse pipeline create-run --workspace-name $SYNAPSE_WORKSPACE --name $SYNAPSE_PIPELINE_NAME --query "runId" -o tsv)

        echo "Synapse Pipeline triggered successfully! Run ID: $SYNAPSE_RUN_ID"
	
	echo "Cleaning up Resources..."

	# Delete Databricks Cluster to Save Cost
	echo "Deleting Databricks cluster $CLUSTER_ID..."
	
	curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/delete" \
		-H "Authorization: Bearer $ACCESS_TOKEN" \
		-H "Content-Type: application/json" \
		-d '{
			"cluster_id": "$CLUSTER_ID"
		   }'

	curl -X POST "https://$DATABRICKS_URL/api/2.0/clusters/permanent-delete" \
		-H "Authorization: Bearer $ACCESS_TOKEN" \
		-H "Content-Type: application/json" \
		-d '{
			"cluster_id": "$CLUSTER_ID"
		   }'

	# Verify Deletion of the Cluster
	VERIFY_DELETE=$(curl -X GET "https://$DATABRICKS_URL/api/2.0/clusters/list" \
		-H "Authorization: Bearer $ACCESS_TOKEN" \
		-H "Content-Type: application/json" | jq -r '.clusters[]? | select(.cluster_id=="'$CLUSTER_ID'") | .cluster_id')

	if [ -z "$VERIFY_DELETE" ]; then
		echo "Cluster $CLUSTER_ID successfully deleted."
	else 
		echo "Error: Cluster $CLUSTER_ID still exists.
		exit 1
	fi

	# Delete Public IP Address
	echo "Deleting IP: $PUBLIC_IP"
	az network public-ip delete --resource-group $RESOURCE_GROUP --name $PUBLIC_IP

	# Check to see if IP exists still
	EXISTING_PUBLIC_IP=$(az network nic show --resource-group $RESOURCE_GROUP --name $NIC_NAME --query "ipConfigurations[0].publicIPAddress.id" -o tsv)

	if [ -z "$EXISTING_PUBLIC_IP" ]; then
		echo "Public IP $PUBLIC_IP successfully deleted."
	else 
		echo "Error: Public IP $PUBLIC_IP still exists."
	fi

	# Stop and Deallocate Windows VM Running the SHIR 
	az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME

	echo "Cleanup Complete." 

    else
       	echo "No changes detected in table $TABLE."
	printf "\n"
    fi
done

echo "Script completed."
