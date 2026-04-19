FROM ghcr.io/fluxcd/flux-cli:v2.8.5@sha256:f1947272d998247ce959adf8ffe13626f153e8b373ccd0322a18b4f7aad132f1 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.46.0@sha256:359ba1c3005d6f564dcf7af35907325f68476ee20395c9aa38477025db94c92e AS flux-operator-cli
FROM mikefarah/yq:4@sha256:603ebff15eb308a05f1c5b8b7613179cad859aed3ec9fdd04f2ef5d32345950e AS yq
FROM alpine/helm:4.1.4@sha256:4b0bdd2cf18ff6bca12aba0b2c5671384dab5035c19c57f0c58b854a0baf65be AS helm
FROM registry.k8s.io/kubectl:v1.35.3@sha256:8dad99b604a2c0bafe17f53cadf78482d6f667a6da687f385508f5f4e4696d37 AS kubectl

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
