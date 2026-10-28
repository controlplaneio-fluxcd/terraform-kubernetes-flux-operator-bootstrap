FROM ghcr.io/fluxcd/flux-cli:v2.10.0@sha256:1a5178b1770052d6e88ab1c7c8434c5ac9bca8a8ab984dcaf6b9df31814ce9f2 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.62.1@sha256:a99df9f7c6e17a25ace20518d5e037175670a9654ed71f8c6c76fb3af9f39915 AS flux-operator-cli
FROM mikefarah/yq:4@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM alpine/helm:4.3.1@sha256:e3f8d5c462d75470fbb1fce79ad5c20063657096d1f98c0fcea869e2600e2e5e AS helm
FROM registry.k8s.io/kubectl:v1.37.2@sha256:fe049faa65ae483ac200009a949a68fa4c9985daea12c9cb1195c9c7965301fc AS kubectl

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
