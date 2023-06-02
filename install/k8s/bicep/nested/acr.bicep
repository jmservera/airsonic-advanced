// bicep for creating an Azure Container Registry
// https://docs.microsoft.com/en-us/azure/templates/microsoft.containerregistry/registries

@description('Globally unique name of your Azure Container Registry')
@minLength(5)
@maxLength(50)
param acrName string = 'acr${uniqueString(resourceGroup().id)}'

@description('Enable admin user that has push / pull permission to the registry.')
param acrAdminUserEnabled bool = false

@description('Location for registry home replica.')
param location string = resourceGroup().location

@description('Tier of your Azure Container Registry. Geo-replication requires Premium SKU.')
@allowed([
  'Standard'
  'Premium'
])
param acrSku string = 'Standard'

resource acr 'Microsoft.ContainerRegistry/registries@2019-12-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  tags: {
    displayName: 'Container Registry'
    'container.registry': acrName
  }
  properties: {
    adminUserEnabled: acrAdminUserEnabled
  }
}

output acrLoginServer string = acr.properties.loginServer
