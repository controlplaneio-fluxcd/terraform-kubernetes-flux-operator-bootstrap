#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "CLUSTER_NAME=\(.name)"')"

context="kind-${CLUSTER_NAME}"

host=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${context}\")].cluster.server}")
ca=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${context}\")].cluster.certificate-authority-data}")
cert=$(kubectl config view --raw -o jsonpath="{.users[?(@.name==\"${context}\")].user.client-certificate-data}")
key=$(kubectl config view --raw -o jsonpath="{.users[?(@.name==\"${context}\")].user.client-key-data}")

jq -n --arg host "$host" --arg ca "$ca" --arg cert "$cert" --arg key "$key" \
  '{"host": $host, "cluster_ca_certificate": $ca, "client_certificate": $cert, "client_key": $key}'
