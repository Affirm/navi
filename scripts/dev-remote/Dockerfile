# Disposable "remote host" for developing Navi's remote-hosts feature:
# sshd + python3 + bash, user `dev`. The plugin's hooks/ are bind-mounted at
# /plugin/hooks by scripts/dev-remote-container.sh. Not for production use.
FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash dev \
    && mkdir -p /run/sshd /home/dev/.ssh \
    && chown dev:dev /home/dev/.ssh && chmod 700 /home/dev/.ssh \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
COPY fake-session.sh /usr/local/bin/navi-fake-session
RUN chmod 755 /usr/local/bin/navi-fake-session
EXPOSE 22
CMD ["/bin/sh", "-c", "install -o dev -g dev -m 600 /keys/authorized_keys /home/dev/.ssh/authorized_keys && ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]
