# Dockerfile — single-stage development image for the frontend.
# Copies the static files into an Nginx container; the entrypoint script
# injects runtime configuration. CI ships Dockerfile.multistage.

FROM nginx:1.30-alpine

LABEL org.opencontainers.image.source="https://github.com/Parzivalart3mis/gitops-cicd-pipeline"
LABEL org.opencontainers.image.description="GitOps demo frontend"
LABEL org.opencontainers.image.licenses="MIT"

# Upgrade Alpine packages to pull the latest security patches at build time.
RUN apk upgrade --no-cache \
    && rm /etc/nginx/conf.d/default.conf \
    && mkdir -p /etc/nginx/snippets

COPY nginx.conf    /etc/nginx/nginx.conf
COPY src/          /usr/share/nginx/html/
COPY entrypoint.sh /entrypoint.sh

# Run as the non-root nginx user (UID 101); it needs write access to the HTML,
# snippets dir, cache, logs and pid file. Nginx listens on 8080.
RUN chmod +x /entrypoint.sh \
    && chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/snippets /var/cache/nginx /var/log/nginx \
    && touch /tmp/nginx.pid \
    && chown nginx:nginx /tmp/nginx.pid

USER 101

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
