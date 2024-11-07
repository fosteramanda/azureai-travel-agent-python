targetScope = 'subscription'

// Common configurations
@description('Name of the environment')
param environmentName string
@description('Principal ID to grant access to the AI services. Leave empty to skip')
param myPrincipalId string
@description('Current principal type being used')
@allowed(['User', 'ServicePrincipal'])
param myPrincipalType string = 'ServicePrincipal'
@description('IP addresses to grant access to the AI services. Leave empty to skip')
param allowedIpAddresses string = ''
var allowedIpAddressesArray = !empty(allowedIpAddresses) ? split(allowedIpAddresses, ',') : []
@description('Resource group name for the AI services. Defauts to rg-<environmentName>')
param resourceGroupName string = ''
@description('Resource group name for the DNS configurations. Defaults to rg-dns')
param dnsResourceGroupName string = ''
@description('Tags for all AI resources created. JSON object')
param tags object = {}

// Network configurations
@description('Allow or deny public network access to the AI services (recommended: Disabled)')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Disabled'
@description('Authentication type to use (recommended: identity)')
@allowed(['identity', 'accessKey'])
param authMode string = 'identity'
@description('Address prefixes for the spoke vNet')
param vnetAddressPrefixes array = ['10.0.0.0/16']
@description('Address prefix for the private endpoint subnet')
param privateEndpointSubnetAddressPrefix string = '10.0.0.0/24'
@description('Address prefix for the application subnet')
param appSubnetAddressPrefix string = '10.0.1.0/24'

// AI Services configurations
@description('Name of the AI Services account. Automatically generated if left blank')
param aiServicesName string = ''
@description('Name of the Bing account. Automatically generated if left blank')
param bingName string = ''
@description('Name of the Bot Service. Automatically generated if left blank')
param botName string = ''

// Other configurations
@description('Name of the Bot Service. Automatically generated if left blank')
param msiName string = ''
@description('Name of the Cosmos DB Account. Automatically generated if left blank')
param cosmosName string = ''
@description('Name of the App Service Plan. Automatically generated if left blank')
param appPlanName string = ''
@description('Name of the App Services Instance. Automatically generated if left blank')
param appName string = ''
@description('Whether to enable authentication (requires Entra App Developer role)')
param enableAuthentication bool = true

@description('Gen AI model name and version to deploy')
@allowed(['gpt-4,1106-Preview', 'gpt-4,0125-Preview', 'gpt-4o,2024-05-13', 'gpt-4o-mini,2024-07-18'])
param model string = 'gpt-4o-mini,2024-07-18'
@description('Tokens per minute capacity for the model. Units of 1000 (capacity = 10 means 10,000 tokens per minute)')
param modelCapacity int = 50

var modelName = split(model, ',')[0]
var modelVersion = split(model, ',')[1]

var abbrs = loadJsonContent('abbreviations.json')
var uniqueSuffix = substring(uniqueString(subscription().id, environmentName), 1, 3)
var location = deployment().location

var names = {
  resourceGroup: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  dnsResourceGroup: !empty(dnsResourceGroupName) ? dnsResourceGroupName : '${abbrs.resourcesResourceGroups}dns'
  msi: !empty(msiName) ? msiName : '${abbrs.managedIdentityUserAssignedIdentities}${environmentName}-${uniqueSuffix}'
  cosmos: !empty(cosmosName) ? cosmosName : '${abbrs.documentDBDatabaseAccounts}${environmentName}-${uniqueSuffix}'
  appPlan: !empty(appPlanName)
    ? appPlanName
    : '${abbrs.webSitesAppServiceEnvironment}${environmentName}-${uniqueSuffix}'
  app: !empty(appName) ? appName : '${abbrs.webSitesAppService}${environmentName}-${uniqueSuffix}'
  bot: !empty(botName) ? botName : '${abbrs.cognitiveServicesBot}${environmentName}-${uniqueSuffix}'
  vnet: '${abbrs.networkVirtualNetworks}${environmentName}-${uniqueSuffix}'
  privateLinkSubnet: '${abbrs.networkVirtualNetworksSubnets}${environmentName}-pl-${uniqueSuffix}'
  appSubnet: '${abbrs.networkVirtualNetworksSubnets}${environmentName}-app-${uniqueSuffix}'
  aiServices: !empty(aiServicesName)
    ? aiServicesName
    : '${abbrs.cognitiveServicesAccounts}${environmentName}-${uniqueSuffix}'
  bing: !empty(bingName)
    ? bingName
    : '${abbrs.cognitiveServicesBing}${environmentName}-${uniqueSuffix}'
}

// Private Network Resources
var dnsZones = [
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.vault.azure.com'
  'privatelink.search.azure.com'
  'privatelink.documents.azure.com'
  'privatelink.api.azureml.ms'
  'privatelink.notebooks.azure.net'
  'privatelink.azurewebsites.net'
]

var dnsZoneIds = publicNetworkAccess == 'Disabled' ? m_dns.outputs.dnsZoneIds : dnsZones
var privateEndpointSubnetId = publicNetworkAccess == 'Disabled' ? m_network.outputs.privateEndpointSubnetId : ''

// Deploy two resource groups
resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: names.resourceGroup
  location: location
  tags: union(tags, { 'azd-env-name': environmentName })
}

resource dnsResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = if (publicNetworkAccess == 'Disabled') {
  name: names.dnsResourceGroup
  location: location
  tags: tags
}

// Network module - deploys Vnet
module m_network 'modules/aistudio/network.bicep' = if (publicNetworkAccess == 'Disabled') {
  name: 'deploy_vnet'
  scope: resourceGroup
  params: {
    location: location
    vnetName: names.vnet
    vnetAddressPrefixes: vnetAddressPrefixes
    privateEndpointSubnetName: names.privateLinkSubnet
    privateEndpointSubnetAddressPrefix: privateEndpointSubnetAddressPrefix
    appSubnetName: names.appSubnet
    appSubnetAddressPrefix: appSubnetAddressPrefix
  }
}

// DNS module - deploys private DNS zones and links them to the Vnet
module m_dns 'modules/aistudio/dns.bicep' = if (publicNetworkAccess == 'Disabled') {
  name: 'deploy_dns'
  scope: dnsResourceGroup
  params: {
    vnetId: publicNetworkAccess == 'Disabled' ? m_network.outputs.vnetId : ''
    vnetName: publicNetworkAccess == 'Disabled' ? m_network.outputs.vnetName : ''
    dnsZones: dnsZones
  }
}

module m_msi 'modules/msi.bicep' = {
  name: 'deploy_msi'
  scope: resourceGroup
  params: {
    location: location
    msiName: names.msi
    tags: tags
  }
}

// AI Services module
module m_aiservices 'modules/aistudio/aiservices.bicep' = {
  name: 'deploy_aiservices'
  scope: resourceGroup
  params: {
    location: location
    aiServicesName: names.aiServices
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: privateEndpointSubnetId
    openAIPrivateDnsZoneId: dnsZoneIds[0]
    cognitiveServicesPrivateDnsZoneId: dnsZoneIds[1]
    authMode: authMode
    grantAccessTo: authMode == 'identity'
      ? [
          {
            id: myPrincipalId
            type: myPrincipalType
          }
          {
            id: m_msi.outputs.msiPrincipalID
            type: 'ServicePrincipal'
          }
        ]
      : []
    allowedIpAddresses: allowedIpAddressesArray
    tags: tags
  }
}

// Bing module
module m_bing 'modules/bing.bicep' = {
  name: 'deploy_bing'
  scope: resourceGroup
  params: {
    location: location
    bingName: names.bing
    // publicNetworkAccess: publicNetworkAccess
    // privateEndpointSubnetId: privateEndpointSubnetId
    // openAIPrivateDnsZoneId: dnsZoneIds[0]
    // cognitiveServicesPrivateDnsZoneId: dnsZoneIds[1]
    // authMode: authMode
    // grantAccessTo: authMode == 'identity'
    //   ? [
    //       {
    //         id: myPrincipalId
    //         type: myPrincipalType
    //       }
    //       {
    //         id: m_msi.outputs.msiPrincipalID
    //         type: 'ServicePrincipal'
    //       }
    //     ]
    //   : []
    // allowedIpAddresses: allowedIpAddressesArray
    tags: tags
  }
}

module m_cosmos 'modules/cosmos.bicep' = {
  name: 'deploy_cosmos'
  scope: resourceGroup
  params: {
    location: location
    cosmosName: names.cosmos
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: privateEndpointSubnetId
    privateDnsZoneId: dnsZoneIds[5]
    allowedIpAddresses: allowedIpAddressesArray
    // We need key based auth here because Bot Framework SDK doesn't support MSI auth for Cosmos DB
    // This can be changed to identity if the SDK supports it in the future
    authMode: authMode
    // authMode: authMode
    grantAccessTo: authMode == 'identity'
      ? [
          {
            id: myPrincipalId
            type: myPrincipalType
          }
          {
            id: m_msi.outputs.msiPrincipalID
            type: 'ServicePrincipal'
          }
        ]
      : []
    tags: tags
  }
}

module m_gpt 'modules/gptDeployment.bicep' = {
  name: 'deploygpt'
  scope: resourceGroup
  params: {
    aiServicesName: m_aiservices.outputs.aiServicesName
    modelName: modelName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
  }
}

module m_app 'modules/appservice.bicep' = {
  name: 'deploy_app'
  scope: resourceGroup
  params: {
    location: location
    appServicePlanName: names.appPlan
    appServiceName: names.app
    tags: tags
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: privateEndpointSubnetId
    privateDnsZoneId: dnsZoneIds[8]
    authMode: authMode
    appSubnetId: publicNetworkAccess == 'Disabled' ? m_network.outputs.appSubnetId : ''
    allowedIpAddresses: allowedIpAddressesArray
    msiID: m_msi.outputs.msiID
    msiClientID: m_msi.outputs.msiClientID
    cosmosName: m_cosmos.outputs.cosmosName
    deploymentName: m_gpt.outputs.modelName
    aiServicesName: m_aiservices.outputs.aiServicesName
    bingName: m_bing.outputs.bingName
  }
}

module m_bot 'modules/botservice.bicep' = {
  name: 'deploy_bot'
  scope: resourceGroup
  params: {
    location: 'global'
    botServiceName: names.bot
    keyVaultName: names.keyVault
    tags: tags
    endpoint: 'https://${m_app.outputs.backendHostName}/api/messages'
    msiClientID: m_msi.outputs.msiClientID
    msiID: m_msi.outputs.msiID
    publicNetworkAccess: publicNetworkAccess
  }
}

output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP_ID string = resourceGroup.id
output AZURE_RESOURCE_GROUP_NAME string = resourceGroup.name
output AZURE_OPENAI_DEPLOYMENT_NAME string = m_gpt.outputs.modelName
output AI_SERVICES_ENDPOINT string = m_aiservices.outputs.aiServicesEndpoint
output BACKEND_APP_NAME string = m_app.outputs.backendAppName
output BACKEND_APP_HOSTNAME string = m_app.outputs.backendHostName
output BOT_NAME string = m_bot.outputs.name
output MSI_PRINCIPAL_ID string = m_msi.outputs.msiPrincipalID
output ENABLE_AUTH bool = enableAuthentication
output AUTH_MODE string = authMode
