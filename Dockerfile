FROM ghcr.io/fluxcd/flux-cli:v2.9.3@sha256:148ad45c3bd6e2f051bda3d1e4572a1f4e546b3fc0b658bf1391ac1ec277a475 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.57.0@sha256:31883f18bc7098fb6f666862d379be6dda59dbd047373440c5423a53d5650a71 AS flux-operator-cli
FROM mikefarah/yq:4@sha256:11a1f0b604b13dbbdc662260d8db6f644b22d8553122a25c1b5b2e8713ca6977 AS yq
FROM alpine/helm:4.2.3@sha256:b97ba4f9b27fe7af16ee3d37e6815783c9d4a51289b6240a9024ec471611ae9b AS helm
FROM registry.k8s.io/kubectl:v1.36.3@sha256:6e4fce3c83651edb91b74bc67701c5cd263dd8aa3cd4254b1798d6425a5ab789 AS kubectl

FROM gcr.io/distroless/static-debian12:debug-nonroot@sha256:8c28702f8a20280cd84526f1abc50c6a91f933e5c3bf792e3e47fd1263146ed7

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
