FROM nginx:alpine

COPY ./app/dashboard.html  /usr/share/nginx/html

EXPOSE 80
