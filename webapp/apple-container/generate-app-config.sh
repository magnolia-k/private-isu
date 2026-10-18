#!/bin/sh
set -eu

: "${APP_HOST:?APP_HOST must be the application container IPv4 address}"
case "${APP_LANGUAGE:-ruby}" in
    php) config=/opt/private-isu/php.conf ;;
    *) config=/opt/private-isu/proxy.conf ;;
esac

sed "s/app:/${APP_HOST}:/g" "$config" > /etc/nginx/conf.d/default.conf
