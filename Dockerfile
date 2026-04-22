FROM ghcr.io/fluxcd/flux-cli:v2.8.6@sha256:8dac34106b9d684ce07b13c9762b5132813c3d477cfd724e9e13cc5944ad771e AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.48.0@sha256:4c5d758913633a041ba541c907c62bcff4247de54a13a898694432869a41f9bd AS flux-operator-cli
FROM mikefarah/yq:4@sha256:0cb4a78491b6e62ee8a9bf4fbeacbd15b5013d19bc420591b05383a696315e60 AS yq
FROM alpine/helm:4.1.4@sha256:4b0bdd2cf18ff6bca12aba0b2c5671384dab5035c19c57f0c58b854a0baf65be AS helm
FROM registry.k8s.io/kubectl:v1.35.4@sha256:e8bc9c71a813d90d5f7689fa57516b2aacd7a02bb9d70d3ab6664ed6d202fc10 AS kubectl

FROM gcr.io/distroless/static-debian12:debug-nonroot@sha256:afead1275cad5ec9662cdc09ce7fe5961a41467555fc30cd46a60247bf8bbdfd

COPY --from=flux-cli --chown=nonroot:nonroot /usr/local/bin/flux /usr/local/bin/flux
COPY --from=flux-operator-cli --chown=nonroot:nonroot /usr/local/bin/flux-operator /usr/local/bin/flux-operator
COPY --from=yq --chown=nonroot:nonroot /usr/bin/yq /usr/local/bin/yq
COPY --from=kubectl --chown=nonroot:nonroot /bin/kubectl /usr/local/bin/kubectl
COPY --from=helm --chown=nonroot:nonroot /usr/bin/helm /usr/local/bin/helm
COPY --chown=nonroot:nonroot scripts/bootstrap.sh /usr/local/bin/bootstrap.sh

RUN ["/usr/local/bin/flux", "version", "--client"]
RUN ["/usr/local/bin/flux-operator", "version", "--client"]
RUN ["/usr/local/bin/helm", "version", "--short"]
RUN ["/usr/local/bin/kubectl", "version", "--client"]
RUN ["/usr/local/bin/yq", "--version"]
RUN ["/busybox/sh", "-n", "/usr/local/bin/bootstrap.sh"]

ENTRYPOINT ["/busybox/sh", "/usr/local/bin/bootstrap.sh"]
