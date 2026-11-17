# Image of this fork's combined build (the `audiencekit-build` branch).
# Same layout as erlangsolutions/mongooseim: the release lives in /usr/lib/mongooseim,
# with its config in /usr/lib/mongooseim/etc, so deployments built on that image only
# need their FROM line changed.
#
#   docker build -f docker/Dockerfile -t mongooseim:audiencekit .
ARG OTP_VERSION=28.4.2

FROM erlang:${OTP_VERSION} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl-dev unixodbc-dev zlib1g-dev libexpat1-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# .git is kept in the context: tools/generate_vsn.sh names the version after it
COPY . .
RUN ./tools/configure \
 && make rel \
 && mv _build/prod/rel/mongooseim /mongooseim

# The slim image already has the OpenSSL runtime that crypto needs
FROM erlang:${OTP_VERSION}-slim
ARG VCS_REF=unknown
LABEL org.opencontainers.image.source="https://github.com/lwm-luminx/MongooseIM" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-2.0-only"
RUN apt-get update \
 && apt-get install -y --no-install-recommends unixodbc zlib1g libexpat1 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /mongooseim /usr/lib/mongooseim
RUN ln -s /usr/lib/mongooseim/bin/mongooseimctl /usr/bin/mongooseimctl
WORKDIR /usr/lib/mongooseim
# 5222 c2s, 5269 s2s, 5280 BOSH/WebSocket, 5285 user GraphQL, 5551 admin GraphQL, 8888 components
EXPOSE 4369 5222 5269 5280 5285 5551 8888
CMD ["/usr/lib/mongooseim/bin/mongooseim", "foreground"]
