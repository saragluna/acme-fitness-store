#!/bin/bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
readonly APPS_ROOT="${PROJECT_ROOT}/apps"

readonly REDIS_NAME="acme-fitness-redis"
readonly COSMOS_ACCOUNT="acme-fitness-cosmosdb"
readonly USER_SERVICE_MONGO_CONNECTION="user_service_mongodb"
readonly ORDER_SERVICE_MONGO_CONNECTION="user_service_mongodb"
readonly CATALOG_SERVICE_MONGO_CONNECTION="catalog_service_mongodb"
readonly ACMEFIT_DB_NAME="acmefit"
readonly USER_DB_NAME="users"
readonly ORDER_DB_NAME="orders"
readonly CART_SERVICE="cart-service"
readonly USER_SERVICE="user-service"
readonly ORDER_SERVICE="order-service"
readonly PAYMENT_SERVICE="payment-service"
readonly CATALOG_SERVICE="catalog-service"
readonly FRONTEND_APP="frontend"
readonly CUSTOM_BUILDER="no-bindings-builder"

RESOURCE_GROUP=''
SPRING_CLOUD_INSTANCE=''

function configure_defaults() {
  echo "Configure azure defaults resource group: $RESOURCE_GROUP and spring-cloud $SPRING_CLOUD_INSTANCE"
  az configure --defaults group=$RESOURCE_GROUP spring-cloud=$SPRING_CLOUD_INSTANCE
}

function create_dependencies() {
  echo "Creating Azure Cache for Redis Instance $REDIS_NAME in location eastus"
  az redis create --location eastus --name $REDIS_NAME --resource-group $RESOURCE_GROUP --sku Basic --vm-size c0

  echo "Creating CosmosDB Account $COSMOS_ACCOUNT"
  az cosmosdb create --name $COSMOS_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --kind MongoDB --server-version "4.0" \
    --default-consistency-level Eventual \
    --enable-automatic-failover true \
    --locations regionName="East US" failoverPriority=0 isZoneRedundant=False

  az cosmosdb mongodb database create --account-name $COSMOS_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --name $ACMEFIT_DB_NAME
}

function create_builder() {
  echo "Creating a custom builder with name $CUSTOM_BUILDER and configuration $PROJECT_ROOT/azure-spring-cloud/builder.json"
  az spring-cloud build-service builder create -n $CUSTOM_BUILDER --builder-file "$PROJECT_ROOT/azure-spring-cloud/builder.json"
}

function configure_gateway() {
  az spring-cloud gateway update --assign-endpoint true
  local gateway_url=$(az spring-cloud gateway show | jq -r '.properties.url')

  echo "Configuring Spring Cloud Gateway without SSO enabled"
  az spring-cloud gateway update \
    --api-description "ACME Fitness API" \
    --api-title "ACME Fitness" \
    --api-version "v.01" \
    --server-url "https://$gateway_url" \
    --allowed-origins "*"
}

function create_cart_service() {
  echo "Creating cart-service app"
  az spring-cloud app create --name $CART_SERVICE
  az spring-cloud gateway route-config create --name $CART_SERVICE --app-name $CART_SERVICE --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/cart-service.json"

  echo "cart-service app successfully created. Please create a service connector to redis before continuing." #TODO: link to instructions
  read -n 1 -s -r -p "Press any key to continue."
}

function create_user_service() {
  echo "Creating user service"
  az spring-cloud app create --name $USER_SERVICE
  az spring-cloud gateway route-config create --name $USER_SERVICE --app-name $USER_SERVICE --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/user-service.json"

  az spring-cloud connection create cosmos-mongo -g $RESOURCE_GROUP \
    --service $SPRING_CLOUD_INSTANCE \
    --app $USER_SERVICE \
    --deployment default \
    --resource-group $RESOURCE_GROUP \
    --target-resource-group $RESOURCE_GROUP \
    --account $COSMOS_ACCOUNT \
    --database $ACMEFIT_DB_NAME \
    --secret \
    --client-type java \
    --connection $USER_SERVICE_MONGO_CONNECTION

  echo "user-service app successfully created. Please create a service connector to redis before continuing." #TODO: link to instructions
  read -n 1 -s -r -p "Press any key to continue."
}

function create_order_service() {
  echo "Creating order service"
  az spring-cloud app create --name $ORDER_SERVICE
  az spring-cloud gateway route-config create --name $ORDER_SERVICE --app-name $ORDER_SERVICE --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/order-service.json"

  az spring-cloud connection create cosmos-mongo -g $RESOURCE_GROUP \
    --service $SPRING_CLOUD_INSTANCE \
    --app $ORDER_SERVICE \
    --deployment default \
    --resource-group $RESOURCE_GROUP \
    --target-resource-group $RESOURCE_GROUP \
    --account $COSMOS_ACCOUNT \
    --database $ACMEFIT_DB_NAME \
    --secret \
    --client-type java \
    --connection $ORDER_SERVICE_MONGO_CONNECTION
}

function create_catalog_service() {
  echo "Creating catalog service"
  az spring-cloud app create --name $CATALOG_SERVICE
  az spring-cloud gateway route-config create --name $CATALOG_SERVICE --app-name $CATALOG_SERVICE --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/catalog-service.json"

  az spring-cloud connection create cosmos-mongo -g $RESOURCE_GROUP \
    --service $SPRING_CLOUD_INSTANCE \
    --app $CATALOG_SERVICE \
    --deployment default \
    --resource-group $RESOURCE_GROUP \
    --target-resource-group $RESOURCE_GROUP \
    --account $COSMOS_ACCOUNT \
    --database $ACMEFIT_DB_NAME \
    --secret \
    --client-type springboot \
    --connection $CATALOG_SERVICE_MONGO_CONNECTION
}

function create_payment_service() {
  echo "Creating payment service"
  az spring-cloud app create --name $PAYMENT_SERVICE
  az spring-cloud gateway route-config create --name $PAYMENT_SERVICE --app-name $PAYMENT_SERVICE --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/payment-service.json"
}

function create_frontend_app() {
  echo "Creating frontend"
  az spring-cloud app create --name $FRONTEND_APP
  az spring-cloud gateway route-config create --name $FRONTEND_APP --app-name $FRONTEND_APP --routes-file "$PROJECT_ROOT/azure-spring-cloud/routes/frontend.json"
}

function deploy_cart_service() {
  echo "Deploying cart-service application"
  local redis_conn_name=$(az spring-cloud connection list --app $CART_SERVICE -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --deployment default | jq -r '.[0].name')
  local redis_conn_str=$(az spring-cloud connection show -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --app $CART_SERVICE --deployment default --connection $redis_conn_name | jq '.configurations[0].value' -r)
  az spring-cloud app deploy --name $CART_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "CART_PORT=8080" "REDIS_CONNECTIONSTRING=$redis_conn_str" "USER_HOST=user-service.default.svc.cluster.local" "USER_PORT=80"\
    --source-path "$APPS_ROOT/acme-cart"
}

function deploy_user_service() {
  echo "Deploying user-service application"
  local mongo_connection_url=$(az spring-cloud connection show -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --deployment default --connection $USER_SERVICE_MONGO_CONNECTION --app $USER_SERVICE | jq '.configurations[0].value' -r)

  local redis_conn_name=$(az spring-cloud connection list --app $USER_SERVICE -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --deployment default --query "[?contains(@.name, 'redis')]" | jq -r '.[0].name')
  local redis_conn_str=$(az spring-cloud connection show -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --app $USER_SERVICE --deployment default --connection $redis_conn_name | jq '.configurations[0].value' -r)

  az spring-cloud app deploy --name $USER_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "USERS_PORT=8080" "MONGODB_CONNECTIONSTRING=$mongo_connection_url" "REDIS_CONNECTIONSTRING=$redis_conn_str" \
    --source-path "$APPS_ROOT/acme-user"
}

function deploy_order_service() {
  echo "Deploying user-service application"
  local mongo_connection_url=$(az spring-cloud connection show -g $RESOURCE_GROUP --service $SPRING_CLOUD_INSTANCE --deployment default --connection $ORDER_SERVICE_MONGO_CONNECTION --app $ORDER_SERVICE | jq '.configurations[0].value' -r)

  az spring-cloud app deploy --name $ORDER_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "OrderDatabaseSettings__ConnectionString=$mongo_connection_url" "AcmeServiceSettings__UserServiceUrl=http://user-service.default.svc.cluster.local" "AcmeServiceSettings__PaymentServiceUrl=http://payment-service.default.svc.cluster.local" \
    --source-path "$APPS_ROOT/acme-order"
}

function deploy_catalog_service() {
  echo "Deploying catalog-service application"

  az spring-cloud app deploy --name $CATALOG_SERVICE \
    --source-path "$APPS_ROOT/acme-catalog"
}

function deploy_payment_service() {
  echo "Deploying payment-service application"

  az spring-cloud app deploy --name $PAYMENT_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "PAYMENT_PORT=8080" "USERS_HOST=user-service.default.svc.cluster.local" "USERS_PORT=80" \
    --source-path "$APPS_ROOT/acme-payment"
}

function deploy_frontend_app() {
  echo "Deploying frontend application"

  rm -rf "$APPS_ROOT/acme-shopping/node_modules"
  az spring-cloud app deploy --name $FRONTEND_APP \
    --builder $CUSTOM_BUILDER \
    --source-path "$APPS_ROOT/acme-shopping"
}

function main() {
  configure_defaults
  create_dependencies
  create_builder
  configure_gateway
  create_user_service
  create_cart_service
  create_order_service
  create_payment_service
  create_catalog_service
  create_frontend_app

  deploy_user_service
  deploy_cart_service
  deploy_order_service
  deploy_payment_service
  deploy_catalog_service
  deploy_frontend_app
}

function usage() {
  echo 1>&2
  echo "Usage: $0 -g <resource_group> -s <spring_cloud_instance>" 1>&2
  echo 1>&2
  echo "Options:" 1>&2
  echo "  -g <namespace>              the Azure resource group to use for the deployment" 1>&2
  echo "  -s <spring_cloud_instance>  the name of the Azure Spring Cloud Instance to use" 1>&2
  echo 1>&2
  exit 1
}

function check_args() {
  if [[ -z $RESOURCE_GROUP ]]; then
    echo "Provide a valid resource group with -g"
    usage
  fi

  if [[ -z $SPRING_CLOUD_INSTANCE ]]; then
    echo "Provide a valid spring cloud instance name with -s"
    usage
  fi
}

while getopts ":g:s:" options; do
  case "$options" in
  g)
    RESOURCE_GROUP="$OPTARG"
    ;;
  s)
    SPRING_CLOUD_INSTANCE="$OPTARG"
    ;;
  *)
    usage
    exit 1
    ;;
  esac

  case $OPTARG in
  -*)
    echo "Option $options needs a valid argument"
    exit 1
    ;;
  esac
done

check_args
main