@description('Base name seed for all resources, <=10 chars')
param baseName string = 'cipp'

@description('URL of your CIPP frontend fork')
param githubRepository string = 'https://github.com/Paulious/CIPP'

@description('GitHub PAT with Static Web Apps deployment scope')
@secure()
param githubToken string

@allowed(['test', 'prod'])
param environmentName string = 'test'

param location string = resourceGroup().location

@description('Static Web Apps is only available in a limited set of regions, independent of the resource group location')
@allowed(['centralus', 'eastus2', 'westus2', 'westeurope', 'eastasia'])
param swaLocation string = 'westeurope'

var suffix        = toLower(substring(uniqueString(resourceGroup().id, environmentName), 0, 5))
var funcAppName   = toLower('${baseName}${environmentName}${suffix}')
var storageName   = toLower('${take(baseName, 12)}st${suffix}')
var planName       = '${take(baseName, 12)}-plan-${suffix}'
var swaName        = toLower('${baseName}-swa-${suffix}')
var kvName          = toLower('${baseName}-kv-${suffix}')
var lawName        = '${baseName}-law-${suffix}'
var appInsightsName = '${baseName}-ai-${suffix}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: environmentName == 'prod' ? 90 : 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: planName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: false }
}

resource funcApp 'Microsoft.Web/sites@2023-01-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      use32BitWorkerProcess: false
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value}' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value}' }
        { name: 'WEBSITE_CONTENTSHARE', value: funcAppName }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'KEYVAULT_NAME', value: kvName }
      ]
    }
  }
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enabledForTemplateDeployment: true
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: funcApp.identity.principalId
        permissions: { secrets: ['get', 'list'] }
      }
    ]
  }
}

resource swa 'Microsoft.Web/staticSites@2023-01-01' = {
  name: swaName
  location: swaLocation
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    repositoryUrl: githubRepository
    branch: 'main'
    repositoryToken: githubToken
    buildProperties: {
      appLocation: '/'
      apiLocation: ''
      outputLocation: '/out'
    }
  }
}

resource swaBackend 'Microsoft.Web/staticSites/userProvidedFunctionApps@2023-01-01' = {
  parent: swa
  name: swaName
  properties: {
    functionAppResourceId: funcApp.id
    functionAppRegion: location
  }
}

output funcAppName string = funcApp.name
output swaDefaultHostname string = swa.properties.defaultHostname
output keyVaultName string = kv.name
output appInsightsName string = appInsights.name
