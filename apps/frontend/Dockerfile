# Dockerfile — single-stage development image for the frontend.
# Copies pre-built static files into an Nginx container.
# The entrypoint script injects runtime environment variables.
# For production use Dockerfile.multistage.

FROM nginx:1.27-alpine

LABEL org.opencontainers.image.source="https://github.com/Parzivalart3mis/gitops-cicd-pipeline"
LABEL org.opencontainers.image.description="GitOps demo frontend"
LABEL org.opencontainers.image.licenses="MIT"

# Upgrade Alpine packages to pull the latest security patches at build time.
# The base nginx image may ship with outdated packages even on the latest tag.
RUN apk upgrade --no-cache

# Remove the default Nginx configuration and replace with ours.
RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY src/       /usr/share/nginx/html/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Run Nginx as a non-root user (nginx user already exists in the alpine image).
# Nginx listens on 8080 (non-privileged port) as configured in nginx.conf.
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /tmp/nginx.pid \
    && chown nginx:nginx /tmp/nginx.pid

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
