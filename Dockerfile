FROM nginxinc/nginx-unprivileged:alpine3.23

COPY ./app/dashboard.html  /usr/share/nginx/html/index.html

EXPOSE 8080
