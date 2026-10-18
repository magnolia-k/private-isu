FROM nginx:1.30

# Keep the same HTTP/FastCGI behavior as the Compose configuration.
COPY etc/nginx/conf.d/default.conf /opt/private-isu/proxy.conf
COPY etc/nginx/conf.d/php.conf.org /opt/private-isu/php.conf
COPY apple-container/generate-app-config.sh /docker-entrypoint.d/generate-app-config.sh
RUN chmod +x /docker-entrypoint.d/generate-app-config.sh
