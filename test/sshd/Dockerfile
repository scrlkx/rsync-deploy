FROM alpine:3.22

RUN apk add --no-cache openssh-server rsync \
    && adduser -D -s /bin/sh deploy \
    && echo "deploy:*" | chpasswd -e

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
