#!/bin/bash

# load .env file
set -o allexport
source .env
set +o allexport

echo "Connect to ACR"
echo $ACR_NAME
read -p "Press enter to continue"

echo "Create user in mysql"
echo "TODO"
read -p "Press enter to continue"
echo "Create user in mysql"
echo -e $(envsubst < create_ad_user.sql)
read -p "Press enter to continue"
echo "Create secrets"
echo -e $(envsubst < secrets.yaml)
read -p "Press enter to continue"
echo "Create deployment"
echo "$(envsubst < deployment.yaml)"