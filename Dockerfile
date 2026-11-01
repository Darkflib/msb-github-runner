# Pin this to a release (e.g. 0.7.13) once you've validated it; msb is still beta.
ARG MSB_VERSION=latest
FROM ghcr.io/superradcompany/microsandbox:${MSB_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq openssl tini \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 controller/msb-runner.sh controller/start-runner.sh /app/

VOLUME /root/.microsandbox
ENTRYPOINT ["tini", "--"]
CMD ["/app/msb-runner.sh"]
