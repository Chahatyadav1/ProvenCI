FROM nginxinc/nginx-unprivileged:alpine3.23-perl

COPY ./app/dashboard.html  /usr/share/nginx/html/index.html

EXPOSE 8080
