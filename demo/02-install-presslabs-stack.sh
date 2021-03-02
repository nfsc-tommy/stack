#!/bin/bash

# NOTE: Only for helm 3!

: ${HELM:=helm}
: ${STACK_CHART:="presslabs/stack"}
: ${CERT_MANAGER_CHART:="jetstack/cert-manager"}
: ${CERT_MANAGER_VERSION:=v0.15.2}

set -x

kubectl create ns presslabs-system
kubectl create namespace cert-manager

"${HELM}" repo add presslabs https://presslabs.github.io/charts
"${HELM}" repo add jetstack https://charts.jetstack.io
"${HELM}" repo update

# apply the CRDs
kustomize build github.com/presslabs/stack/deploy/manifests | kubectl apply -f-

# application CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/application/v0.8.3/config/crd/bases/app.k8s.io_applications.yaml

# install stack
"${HELM}" upgrade -i stack "${STACK_CHART}" \
	--namespace presslabs-system

# install cert-manager
"${HELM}" upgrade -i cert-manager "${CERT_MANAGER_CHART}" \
	--namespace cert-manager \
	--version "${CERT_MANAGER_VERSION}" \
	--set installCRDs=true
