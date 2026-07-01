FROM alpine:3.22

ARG MUTAGEN_VERSION=0.18.1
ARG USER_UID=1000
ARG USER_GID=1000
ARG TARGETARCH
ARG REMOTE_USER=user

RUN apk add --no-cache \
    openssh-client \
    ca-certificates \
    bash \
    curl

RUN case "${TARGETARCH:-arm64}" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/mutagen-io/mutagen/releases/download/v${MUTAGEN_VERSION}/mutagen_linux_${ARCH}_v${MUTAGEN_VERSION}.tar.gz" \
      | tar -xzC /usr/local/bin && \
    chmod +x /usr/local/bin/mutagen

RUN addgroup -g ${USER_GID} app && \
    adduser -D -u ${USER_UID} -G app -s /bin/sh app && \
    mkdir -p /home/app/.ssh /run/ssh-control /workspace && \
    chown -R ${USER_UID}:${USER_GID} /home/app /run/ssh-control /workspace

COPY --chown=${USER_UID}:${USER_GID} --chmod=600 shared/ssh_config /home/app/.ssh/config
RUN sed -i "s/__REMOTE_USER__/${REMOTE_USER}/" /home/app/.ssh/config
COPY --chown=${USER_UID}:${USER_GID} --chmod=755 folders/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV MUTAGEN_VERSION=${MUTAGEN_VERSION}

USER app
WORKDIR /workspace

CMD ["/usr/local/bin/entrypoint.sh"]
