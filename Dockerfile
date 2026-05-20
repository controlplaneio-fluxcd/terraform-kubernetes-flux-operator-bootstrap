FROM ghcr.io/fluxcd/flux-cli:v2.8.7@sha256:4bd0394705637ad5dfd63d70893a56c980d2e438def0b8a4579d54fad9be9593 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.49.0@sha256:94f739d1927e4d24e102408c87e63105355b8f1b5a505d07c741ec68057a799d AS flux-operator-cli
FROM mikefarah/yq:4@sha256:0cb4a78491b6e62ee8a9bf4fbeacbd15b5013d19bc420591b05383a696315e60 AS yq
FROM alpine/helm:4.2.0@sha256:af08f75a3130d666a50b9fc150f40987ef20b885cf67659aabf4b83a5f2c5501 AS helm
FROM registry.k8s.io/kubectl:v1.36.1@sha256:d08f476d04d0e30f426f06bc6ff6c38913aaa4591943046b77e2f74a72d3611c AS kubectl

FROM gcr.io/distroless/static-debian12:debug-nonroot@sha256:f414196eb26b4e7626e29e18776338e5dcc56a2afbe1c64321ab9bf7d7e57c45

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
