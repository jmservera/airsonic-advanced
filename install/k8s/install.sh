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

error() { printf "%s\n" "$*" >&2; }
command 2> >(while read line; do echo -e "\e[01;31m$line\e[0m" >&2; done)

##################################
NOBUILD=0

while getopts j flag
do
    case "${flag}" in
        j) NOBUILD=1;;
    esac
done

# load .env file
set -o allexport
source .env
set +o allexport

# add the rdbms extension to az cli to run mysql commands
prepare_azcli () {
    echo "Preparing az cli"
    # install az cli extension rdbms-connect
    extension=$(az extension list --query "[?name=='rdbms-connect'] | [0]")
    if [ -z "$extension" ]
    then
        az extension add --name rdbms-connect
    else
        echo "rdbms-connect extension already installed"
    fi
}

# login to azure and acr, does subscription selection too
login(){
    export CURRENT_USERNAME=$(az account show --query user.name -o tsv)    
    if [ -z "$CURRENT_USERNAME" ]
    then
        echo "Login to Azure"
        az login
    else
        echo "Already logged in as $CURRENT_USERNAME"
    fi

    if [ ! -z "$SUBSCRIPTION_ID" ]
    then
        echo "Setting subscription to $SUBSCRIPTION_ID"
        az account set --subscription "$SUBSCRIPTION_ID"
    else
        echo "No subscription ID provided, please select a subscription."
        # get list of subscriptions to select one
        ACCOUNTS=$(az account list --query "[].name" -o tsv)
        readarray -t ACCOUNT_LIST < <(echo "$ACCOUNTS")
        PS3="Select subscription: "
        if [ ${#ACCOUNT_LIST[@]} -gt 1 ]
        then
            echo "Select subscription"
            select ACCOUNT_NAME in "${ACCOUNT_LIST[@]}"; do
                if [[ -n $ACCOUNT_NAME ]]; then
                    break
                else
                    echo "Invalid selection."
                fi
            done
            az account set --subscription "$ACCOUNT_NAME"
        fi
    fi

    export ACCOUNT_NAME=$(az account show --query name -o tsv)
    echo "Logged in as $CURRENT_USERNAME in subscription $ACCOUNT_NAME"

    echo "Login to ACR"
    az acr login -n ${ACR_NAME}
}

add_permissions_to_managed_identity(){
    echo "Add permissions to managed identity"
    TENANT_ID=$(az account show --query tenantId -o tsv)
    TOKEN=$(az account get-access-token --resource-type ms-graph --query accessToken --scope https://graph.microsoft.com/.default -o tsv)
    pwsh -c "./permissions.ps1 -TenantId '${TENANT_ID}' -UmiName '${MYSQL_MANAGED_IDENTITY_NAME}' -Token '${TOKEN}'"
}

prepare_workload_identity(){
    echo "Create federated identity linked to workload identity"
    AKS_OIDC_ISSUER="$(az aks show -n ${AKS_CLUSTER} -g "${RESOURCE_GROUP}" --query "oidcIssuerProfile.issuerUrl" -otsv)"
    export WORKLOAD_IDENTITY_ID=$(az identity show -g ${MYSQL_SERVER_RESOURCE_GROUP} -n ${WORKLOAD_IDENTITY_NAME} --query "clientId" -o tsv)
    # this step is crucial, check you have the right namespace selected for the federated service account configuration
    az identity federated-credential create --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} --identity-name ${WORKLOAD_IDENTITY_NAME} --resource-group ${RESOURCE_GROUP} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${KUBERNETES_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
}

prepare_container(){
    if((NOBUILD)); then
        echo "Skipping build"
        return
    fi
    echo "Build .war file and container"
    pushd ../../
    docker run -it --rm --workdir /src   -v $(pwd):/src:rw   -v /tmp/mvnprofile:/root:rw   -v /var/run/docker.sock:/var/run/docker.sock   maven:3.9.1-eclipse-temurin-17   mvn package -DskipTests -P docker
    popd

    echo "Tag and push container"
    docker tag airsonicadvanced/airsonic-advanced:latest ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:${AIRSONIC_VERSION}
    docker tag airsonicadvanced/airsonic-advanced:latest ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:latest
    docker push ${ACR_NAME_FULL}/${AIRSONIC_CONTAINER}:${AIRSONIC_VERSION}
}

prepare_sql () {
    echo "Create managed identity for mysql"
    add_permissions_to_managed_identity
    echo "Create user in mysql"
    # using a temporary file because the --querytext parameter in the az cli gives a syntax error
    (envsubst < create_ad_user.sql) > /tmp/create_ad_user.sql

    az mysql flexible-server execute --admin-user $CURRENT_USERNAME \
                                    --admin-password "$(az account get-access-token --resource-type oss-rdbms --output tsv --query accessToken)" \
                                    --name $MYSQL_SERVER_NAME \
                                    -f /tmp/create_ad_user.sql

    rm /tmp/create_ad_user.sql
}

prepare_aks(){
    echo "Connecting to ACR"
    ACR_CONNECTED=$(az aks check-acr -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} --acr ${ACR_NAME}.azurecr.io 2>/dev/null | grep error)
    if [ -z "$ACR_CONNECTED" ]
    then
        echo "Already connected to ACR"
    else
        echo "Connect to ACR"
        az aks update -n ${AKS_CLUSTER} -g ${RESOURCE_GROUP} --attach-acr ${ACR_NAME}
    fi    
}

deploy_to_aks(){
    pushd templates

    echo "Create secrets"
    export MYSQL_URL="jdbc:mysql://${MYSQL_SERVER_NAME_FULL}:3306/${MYSQL_DATABASE_NAME}?sslMode=REQUIRED&defaultAuthenticationPlugin=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin&authenticationPlugins=com.azure.identity.extensions.jdbc.mysql.AzureMysqlAuthenticationPlugin"
    envsubst < secrets.yaml | kubectl apply -f -

    echo "create service account"
    envsubst < serviceaccount.yaml | kubectl apply -f -

    echo "Create pvc"
    envsubst < azure-pvc.yaml | kubectl apply -f -

    echo "Create deployment"
    envsubst < deployment.yaml | kubectl apply -f -

    echo "Create service"
    envsubst < service.yaml | kubectl apply -f -
    kubectl get pods -w

    popd
}    

# install some prerequisites, like jq, az cli and powershell
./0-prereq.sh
prepare_azcli
login
prepare_container
prepare_aks
prepare_workload_identity
prepare_sql
deploy_to_aks