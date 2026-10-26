# Sidecar image for the envsubst CMP: a minimal Alpine with `envsubst` (gettext). The argocd-cmp-server binary is
# not baked in: repo-server's init container copies it into the shared var-files volume at run time.
FROM alpine:3.24.3
# Unpinned on purpose: Alpine drops old package builds from its mirrors, so an exact pin breaks the build within weeks.
# hadolint ignore=DL3018
RUN apk add --no-cache gettext
USER 999
