#!/bin/bash
TARGET_USER=$(ibmcloud target | grep User | awk '{print $2}')
#check_value "$TARGET_USER"
echo "TARGET_USER=$TARGET_USER"

INGRESS_HOSTNAME=$(ibmcloud cs cluster-get $PIPELINE_KUBERNETES_CLUSTER_NAME --json | grep ingressHostname | tr -d '":,' | awk '{print $2}')
echo "INGRESS_HOSTNAME=${INGRESS_HOSTNAME}"

INGRESS_SECRETNAME=$(ibmcloud cs cluster-get $PIPELINE_KUBERNETES_CLUSTER_NAME --json | grep ingressSecretName | tr -d '":,' | awk '{print $2}')
echo "INGRESS_SECRETNAME=${INGRESS_SECRETNAME}"

if kubectl get namespace $TARGET_NAMESPACE; then
  echo "Namespace $TARGET_NAMESPACE already exists"
else
  echo "Creating namespace $TARGET_NAMESPACE..."
  kubectl create namespace $TARGET_NAMESPACE || exit 1
fi

# copy the tls cert over
# kubectl get secret $INGRESS_SECRETNAME -o yaml | sed 's/namespace: default/namespace: '$TARGET_NAMESPACE'/' | kubectl create -f -

# a secret to access the registry
if kubectl get secret petstore-docker-registry --namespace $TARGET_NAMESPACE; then
  echo "Docker Registry secret already exists"
else
  REGISTRY_TOKEN=$(ibmcloud cr token-add --description "petstore-docker-registry for $TARGET_USER" --non-expiring --quiet)
  kubectl --namespace $TARGET_NAMESPACE create secret docker-registry petstore-docker-registry \
    --docker-server=${REGISTRY_URL} \
    --docker-password="${REGISTRY_TOKEN}" \
    --docker-username=token \
    --docker-email="${TARGET_USER}" || exit 1
fi

CLUSTER_NAMESPACE=$TARGET_NAMESPACE

# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
# reference https://cloud.ibm.com/docs/containers/cs_cluster.html#bx_registry_other
echo "=========================================================="
echo -e "CONFIGURING ACCESS to private image registry from namespace ${CLUSTER_NAMESPACE}"
IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-${REGISTRY_URL}"

echo -e "Checking for presence of ${IMAGE_PULL_SECRET_NAME} imagePullSecret for this toolchain"
if ! kubectl get secret ${IMAGE_PULL_SECRET_NAME} --namespace ${CLUSTER_NAMESPACE}; then
  echo -e "${IMAGE_PULL_SECRET_NAME} not found in ${CLUSTER_NAMESPACE}, creating it"
  # for Container Registry, docker username is 'token' and email does not matter
    if [ -z "${PIPELINE_BLUEMIX_API_KEY}" ]; then PIPELINE_BLUEMIX_API_KEY=${IBM_CLOUD_API_KEY}; fi #when used outside build-in kube job
  kubectl --namespace ${CLUSTER_NAMESPACE} create secret docker-registry ${IMAGE_PULL_SECRET_NAME} --docker-server=${REGISTRY_URL} --docker-password=${PIPELINE_BLUEMIX_API_KEY} --docker-username=iamapikey --docker-email=a@b.com
else
  echo -e "Namespace ${CLUSTER_NAMESPACE} already has an imagePullSecret for this toolchain."
fi
echo "Checking ability to pass pull secret via Helm chart (see also https://cloud.ibm.com/docs/containers/cs_images.html#images)"
CHART_PULL_SECRET=$( grep 'pullSecret' ${CHART_PATH}/values.yaml || : )
if [ -z "${CHART_PULL_SECRET}" ]; then
  echo "INFO: Chart is not expecting an explicit private registry imagePullSecret. Patching the cluster default serviceAccount to pass it implicitly instead."
  echo "      Learn how to inject pull secrets into the deployment chart at: https://kubernetes.io/docs/concepts/containers/images/#referring-to-an-imagepullsecrets-on-a-pod"
  echo "      or check out this chart example: https://github.com/open-toolchain/hello-helm/tree/master/chart/hello"
  SERVICE_ACCOUNT=$(kubectl get serviceaccount default  -o json --namespace ${CLUSTER_NAMESPACE} )
  if ! echo ${SERVICE_ACCOUNT} | jq -e '. | has("imagePullSecrets")' > /dev/null ; then
    kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/default -p '{"imagePullSecrets":[{"name":"'"${IMAGE_PULL_SECRET_NAME}"'"}]}'
  else
    if echo ${SERVICE_ACCOUNT} | jq -e '.imagePullSecrets[] | select(.name=="'"${IMAGE_PULL_SECRET_NAME}"'")' > /dev/null ; then 
      echo -e "Pull secret already found in default serviceAccount"
    else
      echo "Inserting toolchain pull secret into default serviceAccount"
      kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/default --type='json' -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name": "'"${IMAGE_PULL_SECRET_NAME}"'"}}]'
    fi
  fi
  echo "default serviceAccount:"
  kubectl get serviceaccount default --namespace ${CLUSTER_NAMESPACE} -o yaml
  echo -e "Namespace ${CLUSTER_NAMESPACE} authorizing with private image registry using patched default serviceAccount"
else
  echo -e "Namespace ${CLUSTER_NAMESPACE} authorized with private image registry using Helm chart imagePullSecret"
fi

# create the imagePullSecret https://cloud.ibm.com/docs/containers/cs_images.html#store_imagePullSecret
# JMO# kubectl patch -n $TARGET_NAMESPACE serviceaccount/default -p '{"imagePullSecrets":[{"name": "petstore-docker-registry"}]}'

# create mmssearch secret file
cat > "mms-secrets.json" << EOF
{
  "jpetstoreurl": "http://jpetstore.$INGRESS_HOSTNAME",
  "watson": 
  {
    "url": "https://gateway.watsonplatform.net/visual-recognition/api",
    "note": "It may take up to 5 minutes for this key to become active",
    "api_key": "$WATSON_VR_API_KEY"
  },
  "twilio": {
    "sid": "$TWILIO_SID",
    "token": "$TWILIO_TOKEN",
    "number": "$TWILIO_NUMBER"
  }
}
EOF

# create mmssearch secret
echo "### create mmssearch secret..."
kubectl get secret -n $TARGET_NAMESPACE | grep 'mms-secret' &> /dev/null
if [ $? == 0 ]; then
   echo "# deleting existing mms-secret"
   kubectl delete secret mms-secret --namespace $TARGET_NAMESPACE
else
   echo "# mms-secret doesn't exists"
fi

echo "### creating mmssearch secret..."
kubectl --namespace $TARGET_NAMESPACE create secret generic mms-secret --from-file=mms-secrets=./mms-secrets.json


#if [ -z $(kubectl get secret -n $TARGET_NAMESPACE | grep mms-secret) ]
#then
#  kubectl delete secret mms-secret --namespace $TARGET_NAMESPACE
#  echo "# deleting existing mms-secret"
#else
#  echo "# mms-secret doesn't exists"
#fi

# kubectl --namespace $TARGET_NAMESPACE create secret generic mms-secret --from-file=mms-secrets=./mms-secrets.json

## install helm tiller into cluster
# helm init
#echo "##################### AVANT UPGRADE"
#helm version

#helm init --upgrade

#echo "##################### APRES UPGRADE"
#helm version


echo "=========================================================="
echo "CHECKING HELM VERSION: matching Helm Tiller (server) if detected. "
set +e
LOCAL_VERSION=$( helm version --client | grep SemVer: | sed "s/^.*SemVer:\"v\([0-9.]*\).*/\1/" )
TILLER_VERSION=$( helm version --server | grep SemVer: | sed "s/^.*SemVer:\"v\([0-9.]*\).*/\1/" )
set -e
if [ -z "${TILLER_VERSION}" ]; then
  if [ -z "${HELM_VERSION}" ]; then
    CLIENT_VERSION=${HELM_VERSION}
  else
    CLIENT_VERSION=${LOCAL_VERSION}
  fi
else
  echo -e "Helm Tiller ${TILLER_VERSION} already installed in cluster. Keeping it, and aligning client."
  CLIENT_VERSION=${TILLER_VERSION}
fi
if [ "${CLIENT_VERSION}" != "${LOCAL_VERSION}" ]; then
  echo -e "Installing Helm client ${CLIENT_VERSION}"
  WORKING_DIR=$(pwd)
  mkdir ~/tmpbin && cd ~/tmpbin
  curl -L https://storage.googleapis.com/kubernetes-helm/helm-v${CLIENT_VERSION}-linux-amd64.tar.gz -o helm.tar.gz && tar -xzvf helm.tar.gz
  cd linux-amd64
  export PATH=$(pwd):$PATH
  cd $WORKING_DIR
fi
if [ -z "${TILLER_VERSION}" ]; then
    echo -e "Installing Helm Tiller ${CLIENT_VERSION} with cluster admin privileges (RBAC)"
    kubectl -n kube-system create serviceaccount tiller
    kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller
    helm init --service-account tiller
    # helm init --upgrade --force-upgrade
    kubectl --namespace=kube-system rollout status deploy/tiller-deploy
    # kubectl rollout status -w deployment/tiller-deploy --namespace=kube-system
fi
helm version

# install release named jpetstore
helm upgrade --install --namespace $TARGET_NAMESPACE --debug \
  --set image.repository=$REGISTRY_URL/$REGISTRY_NAMESPACE \
  --set image.tag=latest \
  --set image.pullPolicy=Always \
  --set ingress.hosts={jpetstore.$INGRESS_HOSTNAME} \
  --set ingress.secretName=$INGRESS_SECRETNAME \
  --recreate-pods \
  --wait jpetstore ./helm/modernpets

# install release named mmssearch
helm upgrade --install --namespace $TARGET_NAMESPACE --debug \
  --set image.repository=$REGISTRY_URL/$REGISTRY_NAMESPACE \
  --set image.tag=latest \
  --set image.pullPolicy=Always \
  --set ingress.hosts={mmssearch.$INGRESS_HOSTNAME} \
  --set ingress.secretName=$INGRESS_SECRETNAME \
  --recreate-pods \
  --wait mmssearch ./helm/mmssearch
