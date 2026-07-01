FROM caddy:2-alpine

RUN apk add --no-cache bash

COPY gateway/Caddyfile /etc/caddy/Caddyfile.template
COPY --chmod=755 gateway/entrypoint.sh /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
