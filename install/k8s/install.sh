#!/bin/bash

# exit functions
sigterm_handler() { 
  exit 1
}
error() {
  local parent_lineno="$1"
  local message="$2"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi
  exit "${code}"
}

# Setup signal trap for keyboard interrupt
trap 'trap " " SIGINT SIGTERM SIGHUP; kill 0; wait; sigterm_handler' SIGINT SIGTERM SIGHUP
# Setup error handling
trap 'error ${LINENO}' ERR

# colorize stderr
command 2> >(while read line; do echo -e "\e[01;31m$line\e[0m" >&2; done)

# parse arguments
NOBUILD=0
while getopts j flag
do
    case "${flag}" in
        j) NOBUILD=1;;
    esac
done

##################################
# Script starts here
##################################

# load .env file, check .env-demo for an example
set -o allexport
source .env
set +o allexport

# adds the rdbms extension to az cli to run mysql commands
prepare_azcli () {
    echo "[${FUNCNAME[0]}] Preparing az cli"
    # install az cli extension rdbms-connect
    extension=$(az extension list --query "[?name=='rdbms-connect'] | [0]")
    if [ -z "$extension" ]
    then
        az extension add --name rdbms-connect
    else
        echo "[${FUNCNAME[0]}] rdbms-connect extension already installed"
    fi
}

# login to azure and acr, does subscription selection too.
# tries to use the current az cli session if possible
login(){
    export CURRENT_USERNAME=$(az account show --query user.name -o tsv)    
    if [ -z "$CURRENT_USERNAME" ]
    then
        echo "[${FUNCNAME[0]}] Login to Azure"
        az login
    else
        echo "[${FUNCNAME[0]}] Already logged in as $CURRENT_USERNAME"
    fi

    CURRENT_USER_OBJECTID=$(az ad signed-in-user show --query id -o tsv)

    if [ ! -z "$SUBSCRIPTION_ID" ]
    then
        echo "[${FUNCNAME[0]}] Setting subscription to $SUBSCRIPTION_ID"
        az account set --subscription "$SUBSCRIPTION_ID"
    else
        echo "[${FUNCNAME[0]}] No subscription ID provided, please select a subscription."
        # get list of subscriptions to select one
        ACCOUNTS=$(az account list --query "[].name" -o tsv)
        readarray -t ACCOUNT_LIST < <(echo "$ACCOUNTS")
        PS3="Select subscription: "
        if [ ${#ACCOUNT_LIST[@]} -gt 1 ]
        then
            echo "[${FUNCNAME[0]}] Select subscription"
            select ACCOUNT_NAME in "${ACCOUNT_LIST[@]}"; do
                if [[ -n $ACCOUNT_NAME ]]; then
                    break
                else
                    echo "[${FUNCNAME[0]}] Invalid selection."
                fi
            done
            az account set --subscription "$ACCOUNT_NAME"
        fi
    fi

    export ACCOUNT_NAME=$(az account show --query name -o tsv)
    echo "[${FUNCNAME[0]}] Logged in as $CURRENT_USERNAME in subscription $ACCOUNT_NAME"

    echo "[${FUNCNAME[0]}] Login to ACR"
    az acr login -n ${ACR_NAME}
}

# create the mysql server identities, we need two user managed identities
# one for the mysql server and one for the workload.
# the workload identity will be used to access the mysql server from AKS
# the mysql server identity is needed to be able to assign the workload identity
create_identities(){
    echo "[${FUNCNAME[0]}] Create mysql managed identity for the service"
    export UMI=$(az identity show \
                    -g $RESOURCE_GROUP \
                    -n "$MYSQL_MANAGED_IDENTITY_NAME" \
                    --query "principalId" \
                    -o tsv  2>/dev/null)
    if [ -z "$UMI" ]
    then
        export UMI=$(az identity create \
                        -g $RESOURCE_GROUP \
                        -n "$MYSQL_MANAGED_IDENTITY_NAME" \
                        --query "principalId" \
                        -o tsv)
    else
        echo "[${FUNCNAME[0]}] Managed identity already exists"
    fi


    echo "[${FUNCNAME[0]}] Creating workload identity"
    WI=$(az identity show \
            -g $RESOURCE_GROUP \
            -n "$WORKLOAD_IDENTITY_NAME" \
            --query "principalId" \
            -o tsv  2>/dev/null)
    if [ -z "$WI" ]
    then
        az identity create -g $RESOURCE_GROUP -n "$WORKLOAD_IDENTITY_NAME"
    else
        echo "[${FUNCNAME[0]}] Workload identity already exists"
    fi
}

# build the airsonic container
prepare_container(){
    if((NOBUILD)); then
        echo "[${FUNCNAME[0]}] Skipping build"
        return
    fi
    echo "[${FUNCNAME[0]}] Build .war file and container"
    pushd ../../
    # use docker to run maven to build the .war file and the container
    docker run -it --rm --workdir /src -v $(pwd):/src:rw \
      -v /tmp/mvnprofile:/root:rw -v /var/run/docker.sock:/var/run/docker.sock \
      maven:3.9.1-eclipse-temurin-17   mvn package -DskipTests -P docker
    popd

    echo "[${FUNCNAME[0]}] Tag and push container"
    docker tag airsonicadvanced/airsonic-advanced:latest \
     ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:${AIRSONIC_VERSION}
    docker tag airsonicadvanced/airsonic-advanced:latest \
     ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:latest
    docker push ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:${AIRSONIC_VERSION}
}


prepare_aks(){
    echo "[${FUNCNAME[0]}] Connecting to ACR"
    ACR_CONNECTED=$(az aks check-acr -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} \
        --acr ${ACR_NAME}.azurecr.io 2>/dev/null | grep error)
    if [ -z "$ACR_CONNECTED" ]
    then
        echo "[${FUNCNAME[0]}] Already connected to ACR"
    else
        echo "[${FUNCNAME[0]}] Connect to ACR"
        az aks update -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} \
            --attach-acr ${ACR_NAME}
    fi

    echo "[${FUNCNAME[0]}] Add support for workload identity"
    WI_ENABLED=$(az aks show -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} \
        --query "securityProfile.workloadIdentity.enabled" -o tsv)
    OIDC_ENABLED=$( az aks show -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} \
        --query "oidcIssuerProfile.enabled" -o tsv)
    if [ "$WI_ENABLED" = "true" ] && [ "$OIDC_ENABLED" = "true" ]
    then
        echo "[${FUNCNAME[0]}] Workload identity already enabled"
    else
        az aks update \
            -n ${AKS_CLUSTER} \
            -g ${RESOURCE_GROUP} \
            --enable-oidc-issuer \
            --enable-workload-identity
        echo "[${FUNCNAME[0]}] Workload identity enabled"
    fi

    az aks get-credentials \
        -n ${AKS_CLUSTER} \
        -g ${RESOURCE_GROUP} \
        --overwrite-existing
}

prepare_workload_identity(){
    echo "[${FUNCNAME[0]}] Create federated identity linked to workload identity"
    AKS_OIDC_ISSUER="$(az aks show -n ${AKS_CLUSTER} \
                                   -g "${RESOURCE_GROUP}" \
                                   --query "oidcIssuerProfile.issuerUrl" \
                                   -o tsv)"
    export WORKLOAD_IDENTITY_ID=$(az identity show \
                                    -g ${RESOURCE_GROUP} \
                                    -n ${WORKLOAD_IDENTITY_NAME} \
                                    --query "clientId" \
                                    -o tsv)
    # this step is crucial, check you have the right namespace selected for the federated service account configuration
    az identity federated-credential create \
        --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} \
        --identity-name ${WORKLOAD_IDENTITY_NAME} \
        --resource-group ${RESOURCE_GROUP} \
        --issuer ${AKS_OIDC_ISSUER} \
        --subject system:serviceaccount:${KUBERNETES_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
}

add_permissions_to_managed_identity(){
    echo "[${FUNCNAME[0]}] Add permissions to managed identity"
    TENANT_ID=$(az account show --query tenantId -o tsv)
    TOKEN=$(az account get-access-token \
                --resource-type ms-graph \
                --query accessToken \
                --scope https://graph.microsoft.com/.default \
                -o tsv)
    pwsh -c "./permissions.ps1 -TenantId '${TENANT_ID}' -UmiId '${UMI}' -Token '${TOKEN}'"
}

prepare_sql () {
    echo "[${FUNCNAME[0]}] Add mysql server identities"

    id=$(az mysql flexible-server identity show \
            --resource-group $RESOURCE_GROUP \
            --server-name $MYSQL_SERVER_NAME \
            --identity $MYSQL_MANAGED_IDENTITY_NAME \
            --query principalId \
            -o tsv 2>/dev/null)

    echo "[${FUNCNAME[0]}] Managed Identity assignment"
    if [ -z "$id" ]
    then
        az mysql flexible-server identity assign \
            --resource-group $RESOURCE_GROUP \
            --server-name $MYSQL_SERVER_NAME \
            --identity $MYSQL_MANAGED_IDENTITY_NAME
    else
        echo "[${FUNCNAME[0]}] Managed identity already assigned"
    fi

    echo "[${FUNCNAME[0]}] Admin user assignment"
    login=$(az mysql flexible-server ad-admin show \
                --resource-group $RESOURCE_GROUP \
                --server-name $MYSQL_SERVER_NAME \
                --query login \
                -o tsv 2>/dev/null)

    if [ "$CURRENT_USERNAME" != "$login" ]
    then
        az mysql flexible-server ad-admin create \
            --resource-group $RESOURCE_GROUP \
            --server-name $MYSQL_SERVER_NAME \
            --display-name $CURRENT_USERNAME \
            --object-id $CURRENT_USER_OBJECTID \
            --identity $MYSQL_MANAGED_IDENTITY_NAME
    else
        echo "[${FUNCNAME[0]}] Admin user already assigned"
    fi

    MY_IP=$(curl -s ifconfig.me)
    echo "[${FUNCNAME[0]}] Add firewall rules for mysql server for $MY_IP"
    IP=$(az mysql flexible-server firewall-rule show \
                --resource-group $RESOURCE_GROUP \
                --rule-name "${MYSQL_SERVER_NAME}-database-allow-local-ip-wsl" \
                --name "$MYSQL_SERVER_NAME" \
                --query startIpAddress \
                -o tsv  2>/dev/null)
    if [ "$IP" != "$MY_IP" ]
    then   
        az mysql flexible-server firewall-rule create \
            --resource-group $RESOURCE_GROUP \
            --rule-name "${MYSQL_SERVER_NAME}-database-allow-local-ip-wsl" \
            --name "$MYSQL_SERVER_NAME" \
            --start-ip-address "$MY_IP" \
            --end-ip-address "$MY_IP"
    else
        echo "[${FUNCNAME[0]}] Firewall rule for local ip already present"
    fi

    echo "[${FUNCNAME[0]}] Add firewall rules for mysql server for azure services"
    IP=$(az mysql flexible-server firewall-rule show \
                --resource-group $RESOURCE_GROUP \
                --rule-name "${MYSQL_SERVER_NAME}-database-allow-azure" \
                --name "$MYSQL_SERVER_NAME" \
                --query startIpAddress \
                -o tsv  2>/dev/null)
    if [ "$IP" != "0.0.0.0" ]
    then
        az mysql flexible-server firewall-rule create \
            --resource-group $RESOURCE_GROUP \
            --rule-name "${MYSQL_SERVER_NAME}-database-allow-azure" \
            --name "$MYSQL_SERVER_NAME" \
            --start-ip-address "0.0.0.0"
    else
        echo "[${FUNCNAME[0]}] Firewall rule for azure services already present"
    fi


    echo "[${FUNCNAME[0]}] Add needed permissions to the managed identity for mysql"
    add_permissions_to_managed_identity
    echo "[${FUNCNAME[0]}] Create user in mysql"
    # using a temporary file because the --querytext parameter in the az cli gives a syntax error
    (envsubst < create_ad_user.sql) > /tmp/create_ad_user.sql

    TOKEN=$(az account get-access-token \
                --resource-type oss-rdbms \
                --output tsv \
                --query accessToken)
    az mysql flexible-server execute \
        --admin-user $CURRENT_USERNAME \
        --admin-password "$TOKEN" \
        --name $MYSQL_SERVER_NAME \
        --querytext "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE_NAME;"

    az mysql flexible-server execute \
        --admin-user $CURRENT_USERNAME \
        --admin-password "$TOKEN" \
        --name $MYSQL_SERVER_NAME \
        -f /tmp/create_ad_user.sql

    rm /tmp/create_ad_user.sql
}

deploy_to_aks(){
    pushd templates

    echo "[${FUNCNAME[0]}] Create namespace"
    envsubst < ns.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] Create secrets"
    export MYSQL_URL="jdbc:mysql://${MYSQL_SERVER_NAME_FULL}:3306/${MYSQL_DATABASE_NAME}?sslMode=REQUIRED&defaultAuthenticationPlugin=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin&authenticationPlugins=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin"
    envsubst < secrets.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] create service account"
    envsubst < serviceaccount.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] Create pvc"
    envsubst < azure-pvc.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] Create deployment"
    envsubst < deployment.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] Create service"
    envsubst < service.yaml | kubectl apply -f -

    echo "[${FUNCNAME[0]}] Wait for pods to be ready"
    kubectl get pods -n $KUBERNETES_NAMESPACE -w

    popd
}    

# install some prerequisites, like jq, az cli and powershell
./0-prereq.sh
# install the rdbms-connect extension
prepare_azcli
# login to azure and acr, does subscription selection too
login
# creates the two identities needed for mysql
create_identities
# # builds the java with maven and creates the container
prepare_container
# # prepare the AKS cluster for using workload identities
prepare_aks
# prepare the workload identity and federated identity
prepare_workload_identity
# prepare the sql server for using the managed identity
prepare_sql
# deploy airsonic to AKS
deploy_to_aks