FROM ghcr.io/fluxcd/flux-cli:v2.8.8@sha256:3113a880461938a47ab2ec877aecbf19c570e4df9848d20228d1b4d2c7f8a764 AS flux-cli
FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.51.0@sha256:f927e7338ca60d4d76ce35883f78ca830ba440e52e735b80413e080ffc0fac53 AS flux-operator-cli
FROM mikefarah/yq:4@sha256:11a1f0b604b13dbbdc662260d8db6f644b22d8553122a25c1b5b2e8713ca6977 AS yq
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
