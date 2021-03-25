FROM alpine:latest

RUN apk add --no-cache ca-certificates curl bash tar jq
RUN apk --no-cache add git

COPY src/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
