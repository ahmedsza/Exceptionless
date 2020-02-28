# making the assumption that this is running from Azure Shell


---- start install
# Helm 3 should be installed on Azure cloud shell. This should not be required
# I had a stange situation where it was not installed in one instance,
# Had to run this script - and then need to change all references from helm to helm3

helmFile='helm-v3.0.0-linux-amd64.tar.gz'
curl https://get.helm.sh/$helmFile --output $helmFile
tar -xvf $helmFile
mkdir ~/tools
mv linux-amd64/helm ~/tools/helm3
rm $helmFile
rm -r linux-amd64
echo 'export PATH=$PATH:~/tools' >> ~/.bashrc && source ~/.bashrc




--- helm 3 installed

# set these variables

VNUMBER=v61
RESOURCE_GROUP=exceptionless-$VNUMBER
CLUSTER=ahms-ex-k8s-$VNUMBER
VNET=ex-net-$VNUMBER
# env is either dev or prod
ENV=dev
# set appropriate location
LOCATION=southafricanorth

# Set appropriate VNET addresses. 
ADDRESS_PREFIX=10.50.0.0/16
SUBNET_PREFIX=10.50.0.0/18
SERVICE_CIDR=10.50.192.0/18
DNS_SERVICE_IP=10.50.192.10
DOCKER_BRIDGE_ADDRESS=172.16.0.1/16

# change  helm3 if needed - should not be -- see note above
# add relevant helm repos
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add jetstack https://charts.jetstack.io
helm repo update

# delete any current Exceptionless directory should it exist
rm -rf Exceptionless

# clone the forked repo, and then cd into that directory
git clone https://github.com/ahmedsza/Exceptionless.git 
cd Exceptionless/k8s


#create Azure resource group
az group create -n $RESOURCE_GROUP --location $LOCATION

#setup the network
# it's important to have a decent sized network (reserve a /16 for each cluster).
az network vnet create -g $RESOURCE_GROUP -n $VNET --subnet-name $CLUSTER --address-prefixes $ADDRESS_PREFIX --subnet-prefixes $SUBNET_PREFIX --location  $LOCATION
SUBNET_ID="$(az network vnet subnet list --resource-group $RESOURCE_GROUP --vnet-name $VNET --query '[0].id' --output tsv)"

# setup the service principals we will use for AKS. Had issues at times for AKS clusters where it autocreates the SP. This seems to be more consistent
TF_SP=$(az ad sp create-for-rbac --skip-assignment )
echo $TF_SP
# Client ID of the service principal
TF_CLIENT_ID=$(echo $TF_SP | jq '.appId' | sed 's/"//g')
echo $TF_CLIENT_ID
# Client secret of the service principal
TF_CLIENT_SECRET=$(echo $TF_SP | jq '.password' | sed 's/"//g')
echo $TF_CLIENT_SECRET

# create the AKS cluster
az aks create \
    --resource-group $RESOURCE_GROUP \
    --name $CLUSTER \
    --kubernetes-version 1.14.8 \
    --node-count 3 \
    --node-vm-size Standard_D8s_v3 \
    --max-pods 50 \
    --network-plugin azure \
    --vnet-subnet-id $SUBNET_ID \
    --enable-addons monitoring \
    --service-principal $TF_CLIENT_ID \
    --client-secret $TF_CLIENT_SECRET \
    --generate-ssh-keys \
    --location  $LOCATION \
    --docker-bridge-address $DOCKER_BRIDGE_ADDRESS \
    --dns-service-ip $DNS_SERVICE_IP \
    --service-cidr $SERVICE_CIDR

# connect to the AKS cluster
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER --overwrite-existing

# install dashboard, using 2.0 rc2 that supports CRDs (elastic operator)
# https://github.com/kubernetes/dashboard/releases
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended.yaml

# create admin user to login to the dashboard
kubectl apply -f admin-service-account.yaml

# create the kubernetes namespace. this was missing from initial instructions
kubectl create namespace ex-$ENV

# set the namespace
kubectl config set-context --current --namespace=ex-$ENV

# setup elasticsearch operator
# https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-quickstart.html
# https://github.com/elastic/cloud-on-k8s/releases
kubectl apply -f https://download.elastic.co/downloads/eck/1.0.0/all-in-one.yaml

# view ES operator logs
kubectl -n elastic-system logs -f statefulset.apps/elastic-operator

# create elasticsearch and kibana instances
kubectl apply -f ex-$ENV-elasticsearch.yaml
# check on deployment, wait for green
kubectl get elasticsearch
kubectl get es && kubectl get pods -l common.k8s.elastic.co/type=elasticsearch

# wait until green in a loop
STATUS_HEALTH=""
echo $STATUS_HEALTH
while [[ $STATUS_HEALTH != "green" ]]; do sleep 1 ; echo $STATUS_HEALTH;  TEMP=$(kubectl get es -o=jsonpath="{.items[*]['status.health']} "); STATUS_HEALTH="$(echo -e "$TEMP" | tr -d '[:space:]')" ; echo $STATUS_HEALTH; done
echo $STATUS_HEALTH

# get elastic password into env variable

ELASTIC_PASSWORD=""
while [ -z $ELASTIC_PASSWORD ]; do
    sleep 10
    ELASTIC_PASSWORD=$(kubectl get secret "ex-$ENV-es-elastic-user" -o go-template='{{.data.elastic | base64decode }}')
done

echo $ELASTIC_PASSWORD



# install nginx for ingress
helm install nginx-ingress stable/nginx-ingress --namespace kube-system --values nginx-values.yaml
# wait for external ip to be assigned
IP=""
while [ -z $IP ]; do
    sleep 10
    IP="$(kubectl get service -l app=nginx-ingress --namespace kube-system -o=jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')"
done
echo $IP


# get the public ID.. Not sure if I neeed this
PUBLICIPID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$IP')].[id]" --output tsv)
az network public-ip update --ids $PUBLICIPID --dns-name $CLUSTER

# install cert-manager
kubectl apply --validate=false -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.12/deploy/manifests/00-crds.yaml
kubectl create namespace cert-manager
kubectl apply -f cluster-issuer.yaml
helm install cert-manager jetstack/cert-manager --namespace cert-manager --set ingressShim.defaultIssuerName=letsencrypt-prod --set ingressShim.defaultIssuerKind=ClusterIssuer

# TODO: update this file using the cluster name for the dns

# replace the value of in certificates yaml to the DNS that we will use. Making use of nip.IO. Writing the output to a new file

sed "s/ex-k8s-v6.eastus.cloudapp.azure.com/$IP.nip.io/g" certificates.yaml > certificatesupdate2.yaml


# apply the certificate to this new domain, and then view it
kubectl apply -f certificatesupdate2.yaml
kubectl describe certificate tls-secret 

# install redis server
helm install ex-$ENV-redis stable/redis --values redis-values.yaml --namespace ex-$ENV

# get redis password
export REDIS_PASSWORD=$(kubectl get secret --namespace ex-$ENV ex-$ENV-redis -o jsonpath="{.data.redis-password}" | base64 --decode)
echo $REDIS_PASSWORD

# setup the azure storage accounts. Not 100% sure what they are used for. 
STORAGEACCOUNTNAME=exceptionless$VNUMBER
QUEUESTORAGENAME=exceptionlessqueue$VNUMBER

az storage account create \
    --location $LOCATION \
    --name $STORAGEACCOUNTNAME \
    --resource-group $RESOURCE_GROUP \
    --sku Standard_LRS

STORAGECONNECTIONSTRING=$(az storage account show-connection-string \
    --name $STORAGEACCOUNTNAME \
    --resource-group $RESOURCE_GROUP -o tsv)
echo $STORAGECONNECTIONSTRING

az storage account create \
    --location $LOCATION \
    --name $QUEUESTORAGENAME \
    --resource-group $RESOURCE_GROUP \
    --sku Standard_LRS

QUEUECONNECTIONSTRING=$(az storage account show-connection-string \
    --name $QUEUESTORAGENAME \
    --resource-group $RESOURCE_GROUP -o tsv)
echo $QUEUECONNECTIONSTRING

# install exceptionless app.. The only one you really need to change is email connection string.
# the SMTP was not setupo right -- and the one pod did not startup, but not serious for me. Something to look at. 
# if you have workign SMTP set the right value
# everythign else for a POC should be fine
APP_TAG="latest"
API_TAG="latest"
EMAIL_CONNECTIONSTRING="smtps://user%40domain.com:password@smtp.domain.com:465"
REDIS_CONNECTIONSTRING="server=ex-$ENV-redis-master.ex-$ENV.svc.cluster.local,password=$REDIS_PASSWORD\,abortConnect=false"
ELASTIC_CONNECTIONSTRING="server=http://elastic:$ELASTIC_PASSWORD@ex-$ENV-es-http:9200;field-limit=2000"
REDIS_CONNECTIONSTRING="server=ex-$ENV-redis-master:6379\,password=$REDIS_PASSWORD\,abortConnect=false"
STORAGE_CONNECTIONSTRING="provider=azurestorage;$STORAGECONNECTIONSTRING"
BASE_URL_API="dev-api.$IP.nip.io"
BASE_URL_APP="dev-app.$IP.nip.io"
BASE_URL_COLLECTOR="dev-collector.$IP.nip.io"
QUEUE_CONNECTIONSTRING="provider=azurestorage;$QUEUECONNECTIONSTRING"

# delete helm if it does exist
helm delete ex-dev

# install exceptionless and set the variables. Getting these variables right was the key to get this all working
helm install ex-$ENV ./exceptionless --namespace ex-$ENV --values ex-$ENV-values.yaml \
    --set "app.image.tag=$APP_TAG" \
    --set "collector.defaultDomain=$BASE_URL_COLLECTOR" \
    --set "app.defaultDomain=$BASE_URL_APP" \
    --set "api.defaultDomain=$BASE_URL_API" \
    --set "collector.domains[0]=$BASE_URL_COLLECTOR" \
    --set "app.domains[0]=$BASE_URL_APP" \
    --set "api.domains[0]=$BASE_URL_API" \
    --set "api.image.tag=$API_TAG" \
    --set "jobs.image.tag=$API_TAG" \
    --set "elasticsearch.connectionString=$ELASTIC_CONNECTIONSTRING" \
    --set "redis.connectionString=$REDIS_CONNECTIONSTRING" \
    --set "storage.connectionString=$STORAGE_CONNECTIONSTRING" \
    --set "queue.connectionString=$QUEUE_CONNECTIONSTRING" \
    --set "config.EX_Scope=$ENV"


# wait until the pods are up and running

while [[ $(kubectl get pods -l component=ex-$ENV-api -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "waiting for pod" && sleep 1; done


#nanother check
kubectl get pods --show-labels -l 'component=ex-dev-api' -w
# this is the URL for the API 
echo $BASE_URL_API

# this is th URL of the website that you can browse to
echo $BASE_URL_APP
