FROM diegosouzapw/omniroute:3.8.49

# Railway mounts volumes owned by uid 0 and the upstream image runs as `node`
# (uid 1000). The entrypoint repairs ownership as root and then drops back to
# uid 1000 before exec'ing the stock server.
USER root

# Upstream bakes a fixed 1024 MB V8 heap ceiling into the image
# (ENV OMNIROUTE_MEMORY_MB=1024 / NODE_OPTIONS=--max-old-space-size=1024).
# That is wrong in both directions on a platform where the container size is
# chosen at deploy time, so railway-entrypoint.sh recomputes it from the
# cgroup's own memory limit.
#
# Both have to be cleared, not just NODE_OPTIONS: the entrypoint treats a set
# OMNIROUTE_MEMORY_MB as a deployer override and leaves it alone, so the baked
# 1024 would suppress the calculation entirely (measured -- the entrypoint
# reported heap=1024MB in a 2 GB container until this line existed). Clearing
# them keeps a deployer-supplied OMNIROUTE_MEMORY_MB working as an override and
# leaves the entrypoint's value as the only --max-old-space-size on the command
# line.
ENV OMNIROUTE_MEMORY_MB=""
ENV NODE_OPTIONS=""

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["node", "dev/run-standalone.mjs"]
