FROM ghcr.io/fluxcd/flux-cli:v2.9.5@sha256:704d5529535570a495249b643159c93a9aa88ffca07813c974a54b7ba6edbd86 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.59.0@sha256:666d00167ffa494fa70fc9721afe94b47044d1684fed7869d8c894bea87289d4 AS flux-operator-cli
FROM mikefarah/yq:4@sha256:cfc4eee658595834ef304eadb0c3ea721f3b7cb6404ad8b7cb909cc5b5145b23 AS yq
FROM alpine/helm:4.2.4@sha256:76c375eed56144c68d6197c55bc5a4552fb42002190b796729901cbab3ae6e51 AS helm
FROM registry.k8s.io/kubectl:v1.37.0@sha256:5ed410ebac5dc976cc717098994dcdb29bbbd38f6bd65f582311f5be4ba719cf AS kubectl

FROM gcr.io/distroless/static-debian12:debug-nonroot@sha256:d5563cc7f2f44313f332e91138cc8c6a158899afeeeab2fce3b0f9ccdb3cf9ee

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
