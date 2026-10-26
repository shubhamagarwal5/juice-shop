# Packages the application that the CI pipeline has already compiled and tested.
#
# Why not build inside Docker (as Juice Shop's upstream Dockerfile does)?
#   Running `npm install` inside `docker build` fetches packages from npmjs.org directly,
#   bypassing Artifactory, and those dependencies never appear in build-info.
#   Compiling in CI and only packaging here keeps every dependency on the governed path.
#
# Base image: distroless Node.js 24 (no shell, no package manager), which keeps the
# OS attack surface small. The pipeline passes BASE_IMAGE pointing at the Artifactory
# virtual repository so the base image is also pulled through JFrog and scanned by Xray.
# Production recommendation: pin the base image by digest (@sha256:...) rather than tag.

ARG BASE_IMAGE=gcr.io/distroless/nodejs24-debian13:latest
FROM ${BASE_IMAGE}

ARG VCS_REF
ARG BUILD_DATE
LABEL org.opencontainers.image.title="OWASP Juice Shop" \
      org.opencontainers.image.description="Juice Shop built through a governed JFrog pipeline" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.created=$BUILD_DATE

WORKDIR /juice-shop
COPY --chown=65532:0 . .

# Run as the distroless non-root user
USER 65532
EXPOSE 3000
CMD ["/juice-shop/build/app.js"]
