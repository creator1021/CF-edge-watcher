FROM alpine:3.20

RUN apk add --no-cache curl

WORKDIR /app

COPY heartbeat.sh /app/heartbeat.sh

CMD ["/app/heartbeat.sh"]