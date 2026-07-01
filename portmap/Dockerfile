FROM alpine:3.22

ARG USER_UID=1000
ARG USER_GID=1000
ARG REMOTE_USER=user

RUN apk add --no-cache \
    openssh-client \
    ca-certificates \
    bash

RUN addgroup -g ${USER_GID} app && \
    adduser -D -u ${USER_UID} -G app -s /bin/sh app && \
    mkdir -p /home/app/.ssh /run/ssh-control && \
    chown -R ${USER_UID}:${USER_GID} /home/app /run/ssh-control

COPY --chown=${USER_UID}:${USER_GID} --chmod=600 shared/ssh_config /home/app/.ssh/config
RUN sed -i "s/__REMOTE_USER__/${REMOTE_USER}/" /home/app/.ssh/config
COPY --chown=${USER_UID}:${USER_GID} --chmod=755 portmap/entrypoint.sh /usr/local/bin/entrypoint.sh

USER app
WORKDIR /home/app

CMD ["/usr/local/bin/entrypoint.sh"]
