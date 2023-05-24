#!/bin/bash

# load .env file
set -o allexport
source .env
set +o allexport

#echo "Connect to ACR"
#echo $ACR_NAME
#az aks update -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} --attach-acr ${ACR_NAME}
# read -p "Press enter to continue"

echo "Create user in mysql"
echo "TODO"
# read -p "Press enter to continue"
echo "Create user in mysql"
echo -e $(envsubst < create_ad_user.sql)
# read -p "Press enter to continue"
echo "Create secrets"
export MYSQL_URL="jdbc:mysql://${MYSQL_SERVER_NAME_FULL}:3306/${MYSQL_DATABASE_NAME}?sslMode=REQUIRED&defaultAuthenticationPlugin=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin&authenticationPlugins=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin"
echo $MYSQL_URL
envsubst < secrets.yaml | kubectl apply -f -
# read -p "Press enter to continue"

export WORKLOAD_IDENTITY_ID=$(az identity show -g ${MYSQL_SERVER_RESOURCE_GROUP} -n ${WORKLOAD_IDENTITY_NAME} --query "clientId")
echo "create service account"
envsubst < serviceaccount.yaml | kubectl apply -f -
echo "Create pvc"
envsubst < azure-pvc.yaml | kubectl apply -f -
echo "Create deployment"
envsubst < deployment.yaml | kubectl apply -f -
kubectl get pods -w