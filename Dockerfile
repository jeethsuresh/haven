FROM golang:1.25-alpine AS backend
WORKDIR /src
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /haven .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && addgroup -g 10001 haven && adduser -D -u 10001 -G haven haven && mkdir /data && chown haven:haven /data
COPY --from=backend /haven /usr/local/bin/haven
# Build this first with: cd client && flutter build web --release
COPY client/build/web/ /web/
ENV HAVEN_LISTEN=0.0.0.0:8090 HAVEN_DATA=/data HAVEN_WEB=/web
USER haven
EXPOSE 8090
ENTRYPOINT ["haven"]
