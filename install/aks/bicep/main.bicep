/*
  This script creates three resources using these nested templates:
    nested/acr.bicep creates an Azure Container Registry
    nested/aks.bicep for the Azure Kubernetes Service
    nested/mysql.bicep adds a MySQL Flexible Server
  It is a very simple deployment that we use as a starting point to show how
  to convert an AKS cluster with MySQL Flexible Server to use Azure AD
  Workload Identity. 
*/

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

module acr './nested/acr.bicep' = {
  name: 'acr_deployment'
  params: {
    acrName: acrName
    location: location
  }
}

module aks './nested/aks.bicep' = {
  name: 'aks_deployment'
  params: {
    clusterName: clusterName
    location: location
  }
}

module mysql './nested/mysql.bicep' = {
  name: 'mysql_deployment'
  params: {
    serverName: serverName
    databaseName: dbName
    location: location
    administratorLogin: 'airsonic'
    administratorLoginPassword: administratorLoginPassword
  }
}
