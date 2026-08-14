# syntax=docker/dockerfile:1.7

ARG NODE_VERSION=22.17.0
ARG NODE_RUNTIME_VERSION=22.22.2
ARG DISTROLESS_TAG=nonroot

# ---------------------------------------------------------------------------
# base: metadados de dependências compartilhados por dev e build.
# Copiar apenas package*.json aqui garante que alterações em src/ não
# invalidem o cache de `npm ci` das camadas seguintes.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ---------------------------------------------------------------------------
# dev: ambiente de desenvolvimento com reload automático (tsx watch)
# ---------------------------------------------------------------------------
FROM base AS dev
ENV NODE_ENV=development
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["npm", "run", "dev"]

# ---------------------------------------------------------------------------
# build: compila o TypeScript para dist/
# ---------------------------------------------------------------------------
FROM base AS build
ENV NODE_ENV=development
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .
RUN npm run build

# ---------------------------------------------------------------------------
# prod-deps: apenas dependências de produção, isoladas do estágio build
# ---------------------------------------------------------------------------
FROM base AS prod-deps
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# ---------------------------------------------------------------------------
# node-runtime: apenas para extrair o binário do Node em versão de patch
# específica (corrige CVE crítica presente no runtime empacotado nas tags
# "nodejs22-debian12" da distroless, que ficam defasadas em relação aos
# patches de segurança do Node).
# ---------------------------------------------------------------------------
FROM node:${NODE_RUNTIME_VERSION}-bookworm-slim AS node-runtime

# ---------------------------------------------------------------------------
# production: distroless "cc" (glibc + libstdc++, sem shell/gerenciador de
# pacotes) + binário do Node copiado da imagem oficial acima, já não-root.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/cc-debian12:${DISTROLESS_TAG} AS production
WORKDIR /app
ENV NODE_ENV=production
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/node", "-e", "fetch('http://localhost:3000/health').then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))"]

LABEL org.opencontainers.image.title="fc4-flags-api" \
      org.opencontainers.image.description="API REST de feature flags em Node.js + TypeScript com persistência em PostgreSQL" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.source="https://github.com/brito101/fc4-desafio-docker-node-api"

ENTRYPOINT ["/usr/local/bin/node"]
CMD ["dist/server.js"]
