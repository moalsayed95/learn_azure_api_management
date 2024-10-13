@allowed([
  'swedencentral'
])
@description('Azure location where resources should be deployed (e.g., swedencentral)')
param location string = 'swedencentral'

var prefix = 'hackapim'
var suffix = uniqueString(resourceGroup().id)
var databaseAccountName = '${prefix}-cosmosdb-${suffix}'
var databaseName = 'callcenter'
var databaseContainerName = 'calls'
var apiManagementName = '${prefix}-apim-${suffix}'

var locations = [
  {
    locationName: location
    failoverPriority: 0
    isZoneRedundant: false
  }
]

/*
  Create a Cosmos DB account with a database and a container
*/

resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2021-04-15' = {
  name: databaseAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: locations
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false

  }
}

resource cosmosDbDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2021-04-15' = {
  parent: cosmosDbAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource cosmosDbContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2021-04-15' = {
  parent: cosmosDbDatabase
  name: databaseContainerName
  properties: {
    resource: {
      id: databaseContainerName
      partitionKey: {
        paths: ['/partitionKey']
        kind: 'Hash'
      }
    }
  }
}

resource apiManagement 'Microsoft.ApiManagement/service@2021-08-01' = {
  name: apiManagementName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: 'admin@example.com'
    publisherName: 'Admin'
  }
}

/*
  Create Azure AI Search
*/

var searchServiceName = '${prefix}-search-${suffix}'

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    hostingMode: 'default'
  }
}


/* 
  Create Azure AI Studio
*/

var aiCognitiveServicesName = '${prefix}-aiservices-${suffix}'
var aiKeyvaultName = replace('${prefix}-kv-${suffix}', '-', '')
var aiStorageAccountName = toLower(take(replace('${prefix}-strg-${suffix}', '-', ''), 24))
var aiHubName = '${prefix}-aistudio-${suffix}'
var aiHubFriendlyName = 'GenAI Call Center AI Studio'
var aiHubDescription = 'This is an example AI resource for use in Azure AI Studio.'
var aiHubProjectName = 'CallCenter'

resource aiKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: aiKeyvaultName
  location: location
  properties: {
    createMode: 'default'
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableSoftDelete: true
    enableRbacAuthorization: true
    enablePurgeProtection: true
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 7
    tenantId: subscription().tenantId
  }
}

resource aiStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: aiStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

resource aiCognitiveServices 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: aiCognitiveServicesName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices' 
  properties: {
    apiProperties: {
      statisticsEnabled: false
    }
  }
}

resource aiCognitiveServicesDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  name: 'gpt-4o-mini'
  parent: aiCognitiveServices
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
  }
  sku: {
    name: 'GlobalStandard'
    capacity: 120
  }
}

resource aiCognitiveServicesDeployment2 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  name: 'text-embedding-ada-002'
  parent: aiCognitiveServices
  dependsOn: [
    aiCognitiveServicesDeployment
  ]
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-ada-002'
      version: '2'
    }
  }
  sku: {
    name: 'Standard'
    capacity: 20
  }
}

var appLogAnalyticsWorkspaceName = '${prefix}-loganalytics-${suffix}'
var appApplicationInsightsName = '${prefix}-appinsights-${suffix}'

resource appLogAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: appLogAnalyticsWorkspaceName
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

resource appApplicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appApplicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: appLogAnalyticsWorkspace.id
  }
}

resource aiHub 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: aiHubName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'hub'
  properties: {
    // organization
    friendlyName: aiHubFriendlyName
    description: aiHubDescription

    // dependent resources
    keyVault: aiKeyVault.id
    storageAccount: aiStorageAccount.id
    applicationInsights: appApplicationInsights.id
    
    publicNetworkAccess: 'Enabled'
  }

  resource aiServicesConnection 'connections@2024-07-01-preview' = {
    name: '${aiHubName}-aiservices'
    properties: {
      category: 'AIServices'
      target: aiCognitiveServices.properties.endpoint
      authType: 'ApiKey'
      isSharedToAll: true
      useWorkspaceManagedIdentity: true
      credentials: {
        key: aiCognitiveServices.listKeys().key1
      }
      metadata: {
        ApiType: 'Azure'
        ResourceId: aiCognitiveServices.id
      }
    }
  }

  resource aiSearchConnection 'connections@2024-07-01-preview' = {
    name: '${aiHubName}-search'
    properties: {
      category: 'CognitiveSearch'
      target: 'https://${searchServiceName}.search.windows.net'
      authType: 'ApiKey'
      isSharedToAll: true
      useWorkspaceManagedIdentity: true
      credentials: {
        key: searchService.listAdminKeys().primaryKey
      }
      metadata: {
        ApiType: 'Azure'
        ResourceId: aiCognitiveServices.id
      }
    }
  }
}

resource aiHubProject 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: aiHubProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'project'
  properties: {
    description: 'Call Center AI Studio Project'
    friendlyName: 'Call Center'
    hubResourceId: aiHub.id
    hbiWorkspace: false
    v1LegacyMode: false
    publicNetworkAccess: 'Enabled'
  }
}

/*
  Return output values
*/

output cosmosDbAccountName string = cosmosDbAccount.name
output cosmosDbAccountEndpoint string = cosmosDbAccount.properties.documentEndpoint
output databaseName string = cosmosDbDatabase.name
output containerName string = cosmosDbContainer.name
output apiManagementName string = apiManagement.name
output apiManagementEndpoint string = apiManagement.properties.gatewayUrl
output aiCognitiveServicesName string = aiCognitiveServicesName
output aiHubName string = aiHubName
output aiHubProjectName string = aiHubProjectName
