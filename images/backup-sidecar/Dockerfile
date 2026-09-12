# The house backup sidecar (ADR-0006, docs/specs/backup-sidecar.md). One image for every app VM:
# resticprofile + restic + rclone from upstream's release image, supercronic so the schedule runs
# as whatever `user:` compose sets, and the house profile baked in. Upstream's image schedules
# through busybox crond, which needs root — the one thing this image exists to avoid.
#
# Everything app-specific arrives at runtime: BACKUP_SLUG, BASE_DOMAIN, BACKUP_SCHEDULE,
# BACKUP_PING_URL as environment; credentials as file-secrets under /run/secrets; the backup set
# as read-only binds under /backup. See the README next to this file.
FROM ghcr.io/creativeprojects/resticprofile:0.33.1

# supercronic: crontab-file cron that runs in the foreground as any user, logs to stdout, and
# skips a run whose predecessor is still going.
RUN apk add --no-cache supercronic

COPY profiles.yaml /etc/resticprofile/profiles.yaml
COPY backup /usr/local/bin/backup

# The target list is the ONE house-wide fact in this image — a new restic-server target is a new
# profile in profiles.yaml, a new name here, one new credential file per VM, and an image bump.
ENV BACKUP_TARGETS="nfs rsync-net pcloud" \
    RESTIC_CACHE_DIR=/cache \
    HOME=/tmp

ENTRYPOINT ["/usr/local/bin/backup"]
CMD ["schedule"]
