#!/bin/sh
set -eu

if cluster_status=$(aws eks describe-cluster --region "$AWS_REGION" \
    --name "$EKS_CLUSTER_NAME" --query 'cluster.status' --output text 2>&1); then
    if [ "$cluster_status" != ACTIVE ]; then
        aws eks wait cluster-active --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
    fi
else
    case "$cluster_status" in
        *ResourceNotFoundException*) echo "EKS cluster is already absent."; exit 0 ;;
        *) printf '%s\n' "$cluster_status" >&2; exit 1 ;;
    esac
fi

export KUBECONFIG="$(mktemp)"
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG"

services=$(kubectl get services -A -o json)
ingresses=$(kubectl get ingress -A -o json)
if printf '%s\n' "$services" | jq -e 'any(.items[]; .spec.type == "LoadBalancer")' > /dev/null ||
    printf '%s\n' "$ingresses" | jq -e '.items | length > 0' > /dev/null; then
    echo "Remove lab-owned LoadBalancer Services and Ingresses before destroying EKS." >&2
    kubectl get svc,ingress -A
    exit 1
fi

kubectl -n "$PATHNEX_MONITORING_NAMESPACE" delete svc pathnex-grafana-nodeport --ignore-not-found
helm uninstall pathnex-monitoring -n "$PATHNEX_MONITORING_NAMESPACE" --ignore-not-found --wait
helm uninstall pathnex -n "$PATHNEX_NAMESPACE" --ignore-not-found --wait
