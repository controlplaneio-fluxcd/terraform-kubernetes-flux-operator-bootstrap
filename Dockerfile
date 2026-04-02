FROM ghcr.io/fluxcd/flux-cli:v2.8.3@sha256:1fe5c39881c0c1f857f0462f0692e365bea768228b33d31c209610f389775eb6 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.45.1@sha256:cf844df62557316644f07851ac3fae4aa00daaad3a018b53bd5add95bcfda907 AS flux-operator-cli

FROM alpine:3.23@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS builder

ARG HELM_VERSION=v4.1.3
ARG KUBECTL_VERSION=v1.35.3
ARG TARGETOS=linux
ARG TARGETARCH=amd64

COPY --from=flux-cli /usr/local/bin/flux /out/usr/local/bin/flux
COPY --from=flux-operator-cli /usr/local/bin/flux-operator /out/usr/local/bin/flux-operator

RUN apk add --no-cache bash ca-certificates curl tar gzip && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${TARGETOS}-${TARGETARCH}.tar.gz" | tar -xz -C /tmp && \
    mv "/tmp/${TARGETOS}-${TARGETARCH}/helm" /out/usr/local/bin/helm && \
    curl -fsSL -o /out/usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${TARGETOS}/${TARGETARCH}/kubectl" && \
    chmod +x /out/usr/local/bin/flux /out/usr/local/bin/flux-operator /out/usr/local/bin/helm /out/usr/local/bin/kubectl

COPY scripts/bootstrap.sh /out/usr/local/bin/bootstrap.sh
RUN chmod +x /out/usr/local/bin/bootstrap.sh

FROM gcr.io/distroless/static-debian12:debug-nonroot@sha256:afead1275cad5ec9662cdc09ce7fe5961a41467555fc30cd46a60247bf8bbdfd

COPY --from=builder --chown=nonroot:nonroot /out/ /

RUN ["/usr/local/bin/flux", "version", "--client"]
RUN ["/usr/local/bin/flux-operator", "version", "--client"]
RUN ["/usr/local/bin/helm", "version", "--short"]
RUN ["/usr/local/bin/kubectl", "version", "--client"]
RUN ["/busybox/sh", "-n", "/usr/local/bin/bootstrap.sh"]

ENTRYPOINT ["/busybox/sh", "/usr/local/bin/bootstrap.sh"]
