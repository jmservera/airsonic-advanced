#!/bin/bash

# load .env file
set -o allexport
source .env
set +o allexport

prepare_azcli () {
    echo "prepare"
    # install az cli extension rdbms-connect
    az extension add --name rdbms-connect    
              }

login(){
#    az login
    export CURRENT_USERNAME=$(az account show --query user.name -o tsv)
}

prepare_identity(){
    AKS_OIDC_ISSUER="$(az aks show -n ${AKS_CLUSTER} -g "${RESOURCE_GROUP}" --query "oidcIssuerProfile.issuerUrl" -otsv)"
    export WORKLOAD_IDENTITY_ID=$(az identity show -g ${MYSQL_SERVER_RESOURCE_GROUP} -n ${WORKLOAD_IDENTITY_NAME} --query "clientId" -o tsv)
    # this step is crucial, check you have the right namespace selected for the federated service account configuration
    az identity federated-credential create --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} --identity-name ${WORKLOAD_IDENTITY_NAME} --resource-group ${RESOURCE_GROUP} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${KUBERNETES_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
}

prepare_sql () {
    echo "Create user in mysql"
    # using a temporary file because the --querytext parameter in the az cli gives a syntax error
    (envsubst < create_ad_user.sql) > /tmp/create_ad_user.sql

    az mysql flexible-server execute --admin-user $CURRENT_USERNAME \
                                    --admin-password "$(az account get-access-token --resource-type oss-rdbms --output tsv --query accessToken)" \
                                    --name $MYSQL_SERVER_NAME \
                                    -f /tmp/create_ad_user.sql
                                    }
    rm /tmp/create_ad_user.sql

#prepare_azcli
login
prepare_identity
prepare_sql

#echo "Connect to ACR"
#echo $ACR_NAME
#az aks update -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} --attach-acr ${ACR_NAME}
# read -p "Press enter to continue"


# read -p "Press enter to continue"
echo "Create secrets"
export MYSQL_URL="jdbc:mysql://${MYSQL_SERVER_NAME_FULL}:3306/${MYSQL_DATABASE_NAME}?sslMode=REQUIRED&defaultAuthenticationPlugin=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin&authenticationPlugins=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin"
envsubst < secrets.yaml | kubectl apply -f -
# read -p "Press enter to continue"

echo "create service account"
envsubst < serviceaccount.yaml | kubectl apply -f -

echo "Create pvc"
envsubst < azure-pvc.yaml | kubectl apply -f -

echo "Create deployment"
envsubst < deployment.yaml | kubectl apply -f -

echo "Create service"
envsubst < service.yaml | kubectl apply -f -
kubectl get pods -w