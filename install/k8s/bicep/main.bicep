// call the three nested templates
// nested/acr.bicep for ACR
// nested/aks.bicep for AKS
// nested/mysql.bicep for MySQL

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('Globally unique name of your Azure Container Registry')
@minLength(5)
@maxLength(50)
param acrName string = 'acr${uniqueString(resourceGroup().id)}'

@description('The name of the Managed Cluster resource.')
param clusterName string = 'aks${uniqueString(resourceGroup().id)}'

@description('Provide a name for creating the MySQL server.')
param serverName string= 'mysql${uniqueString(resourceGroup().id)}'

@description('Provide a prefix for creating the MySQL resource names.')
param dbName string= 'db${uniqueString(resourceGroup().id)}'

@description('Provide the administrator login password for the MySQL server.')
@secure()
param administratorLoginPassword string

module acr 'nested/acr.bicep' = {
  name: 'acr_deployment'
  params: {
    acrName: acrName
    location: location
  }
}

module aks 'nested/aks.bicep' = {
  name: 'aks_deployment'
  params: {
    clusterName: clusterName
    location: location
  }
}

module mysql 'nested/mysql.bicep' = {
  name: 'mysql_deployment'
  params: {
    serverName: serverName
    databaseName: dbName
    location: location
    administratorLogin: 'airsonic'
    administratorLoginPassword: administratorLoginPassword
  }
}
