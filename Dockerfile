FROM ghcr.io/fluxcd/flux-cli:v2.8.3@sha256:1fe5c39881c0c1f857f0462f0692e365bea768228b33d31c209610f389775eb6 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.45.1@sha256:cf844df62557316644f07851ac3fae4aa00daaad3a018b53bd5add95bcfda907 AS flux-operator-cli
FROM mikefarah/yq:4@sha256:603ebff15eb308a05f1c5b8b7613179cad859aed3ec9fdd04f2ef5d32345950e AS yq
FROM alpine/helm:4.1.3@sha256:a572075a78666ad6fb1f40cb477a9e2eabbc46f3739beeb81904a6121f6ef027 AS helm
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
