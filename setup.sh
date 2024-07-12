set -e

gum confirm '
This script will setup up everything required to run the demo.
Are you ready to start?
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

rm -f .env

export KUBECONFIG=$PWD/kubeconfig.yaml
echo "export KUBECONFIG=$KUBECONFIG" >> .env

echo "## Do you want to create a KinD (local), EKS, GKE, or no cluster (choose none if you already have one)?" | gum format
CLUSTER_TYPE=$(gum choose "kind" "eks" "gke" "none")
echo "export CLUSTER_TYPE=$CLUSTER_TYPE" >> .env

if [[ "$CLUSTER_TYPE" == "kind" ]]; then

    kind create cluster

elif [[ "$CLUSTER_TYPE" == "eks" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input \
        --placeholder "AWS Access Key ID" \
        --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input \
        --placeholder "AWS Secret Access Key" \
        --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
        >> .env

    eksctl create cluster --config-file eksctl.yaml \
        --kubeconfig kubeconfig.yaml

elif [[ "$CLUSTER_TYPE" == "gke" ]]; then

    export USE_GKE_GCLOUD_AUTH_PLUGIN=True

    export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud auth login

    gcloud projects create $PROJECT_ID

    echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID in a browser and enable the Kubernetes API." \
            | gum format

    gum input --placeholder "Press the enter key to continue."

    export KUBECONFIG=$PWD/kubeconfig.yaml
    echo "export KUBECONFIG=$KUBECONFIG" >> .env

    gcloud container clusters create dot --project $PROJECT_ID \
        --zone us-east1-b --machine-type e2-standard-2 \
        --num-nodes 2 --enable-network-policy \
        --no-enable-autoupgrade

fi


helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename config.yaml

kubectl apply --filename providers/kubernetes-incluster.yaml

kubectl apply --filename providers/helm-incluster.yaml

gum spin --spinner dot \
    --title "Waiting for Crossplane providers to be deployed..." \
    -- sleep 60

gum spin --spinner dot \
    --title "Waiting for Crossplane providers to be deployed..." \
    -- kubectl wait \
    --for=condition=healthy provider.pkg.crossplane.io --all \
    --timeout 5m

GITHUB_TOKEN=$(gum input --placeholder "GitHub Token" \
    --value "$GITHUB_TOKEN")
echo "export GITHUB_TOKEN=$GITHUB_TOKEN" >> .env

GITHUB_OWNER=$(gum input --placeholder "GitHub user or owner" \
    --value "$GITHUB_OWNER")
echo "export GITHUB_OWNER=$GITHUB_OWNER" >> .env

echo "
apiVersion: v1
kind: Secret
metadata:
  name: github
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: '{\"token\":\"${GITHUB_TOKEN}\",\"owner\":\"${GITHUB_OWNER}\"}'
" | kubectl --namespace crossplane-system apply --filename -

kubectl apply --filename providers/provider-github-config.yaml

echo "## Which Hyperscaler do you want to use?" | gum format
HYPERSCALER=$(gum choose "aws" "none")

if [[ "$HYPERSCALER" == "aws" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" \
        --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env

    AWS_SECRET_ACCESS_KEY=$(gum input \
        --placeholder "AWS Secret Access Key" \
        --value "$AWS_SECRET_ACCESS_KEY")
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    echo "[default]
    aws_access_key_id = $AWS_ACCESS_KEY_ID
    aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
    " >aws-creds.conf

    kubectl --namespace crossplane-system \
        create secret generic aws-creds \
        --from-file creds=./aws-creds.conf

    kubectl apply --filename providers/provider-aws-config.yaml

else

    yq --inplace ".spec.parameters.db.enabled = false" \
        examples/repo.yaml
    
fi

kubectl create namespace a-team

kubectl create namespace git-repos

REPO_URL=$(git config --get remote.origin.url)

helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd --create-namespace \
    --values argocd-values.yaml --wait

yq --inplace \
    ".spec.source.repoURL = \"https://github.com/$GITHUB_OWNER/crossplane-gh\"" \
    argocd-apps.yaml

kubectl apply --filename argocd-apps.yaml

yq --inplace \
    ".spec.parameters.repo.user = \"$GITHUB_OWNER\"" \
    examples/repo.yaml

yq --inplace \
    ".spec.parameters.gitops.user = \"$GITHUB_OWNER\"" \
    examples/repo.yaml
