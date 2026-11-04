# Build stage for client
# Pin to the native build platform: the client build emits arch-independent
# static assets, so building under QEMU emulation for arm/v7 is wasteful and
# OOMs Node's ~1GB 32-bit heap cap. Build once natively for every target arch.
FROM --platform=$BUILDPLATFORM node:22-alpine AS client-build
WORKDIR /app
COPY package.json package-lock.json ./
COPY client/package.json ./client/package.json
COPY server/package.json ./server/package.json
RUN npm ci --workspace client
COPY client/ ./client/
WORKDIR /app/client
RUN npm run build

# Production stage
FROM node:22-alpine AS production
WORKDIR /app

# Copy server source and dependencies
COPY package.json package-lock.json ./
COPY client/package.json ./client/package.json
COPY server/package.json ./server/package.json
RUN apk add --no-cache --virtual .build-deps python3 make g++ gcc && \
      npm ci --omit=dev --workspace server && \
      apk del .build-deps && \
      npm cache clean --force && \
      rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /root/.npm

COPY server/src ./src
COPY server/docs ./docs

# Copy client build
COPY --from=client-build /app/client/build /client/build

# Data directory (server/src/config/database.js resolves it to /data/snippets),
# owned by the unprivileged user the app runs as.
RUN apk add --no-cache su-exec && \
      mkdir -p /data/snippets && \
      chown node:node /data/snippets

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

EXPOSE 5000

# The image starts as root only so docker-entrypoint.sh can fix the ownership of
# data volumes written by older (root) images; it then drops to the "node" user
# with su-exec before starting the app, so the server never runs as root.
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
# nosemgrep: dockerfile.security.missing-user.missing-user
CMD ["node", "src/app.js"]
