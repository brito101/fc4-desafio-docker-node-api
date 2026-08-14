# fc4-flags-api - Containerização (Do Dev à Produção)

Entrega do desafio **"Do Dev à Produção: Containerizando uma API Node.js"** da Full Cycle 4.0 (trilha Docker para Produção). O código da aplicação (`src/`, `package.json`, `package-lock.json`, `tsconfig.json`, migrações) não foi alterado - a entrega é puramente a camada de containers.

## Sobre a entrega

A API de feature flags (Node.js + TypeScript + PostgreSQL) ganhou dois ambientes de container totalmente automatizados a partir de um único `Dockerfile` multi-stage. O ambiente de **desenvolvimento** roda a partir do código-fonte com `tsx watch`, hot-sync/rebuild via `docker compose watch` e um cliente de banco (Adminer) sob demanda. O ambiente de **produção** consome uma imagem já compilada, publicada multi-arch (amd64/arm64) no Docker Hub com SBOM e provenance assinados, rodando sobre uma base distroless sem shell nem gerenciador de pacotes.

Em ambos os ambientes as migrações do banco (`dist/db/migrate.js` / `npm run db:migrate`) são aplicadas por um serviço `migrate` de execução única, orquestrado pelo Compose via `depends_on: condition: service_completed_successfully` - nenhum passo manual é necessário além de `cp .env.example .env` e o `up`.

## Imagem no Docker Hub

- Repositório: <https://hub.docker.com/r/brito101/fc4-flags-api>
- Pull: `docker pull brito101/fc4-flags-api:1.0.0`
- Digest do manifest list (`1.0.0` e `latest` apontam para o mesmo digest):
  `sha256:9b7941852323b72498d3bf24263806b65fe203d95f41de55d72d4ba1aa7f01a7`
- Plataformas: `linux/amd64`, `linux/arm64`

Comparação de tamanho (`docker image ls` após `docker pull`, plataforma `linux/amd64`):

| Imagem                                 | Disk usage | Content size |
| -------------------------------------- | ---------: | -----------: |
| `fc4-flags-api:dev` (estágio dev)      |     ~455 MB |       ~106 MB |
| `brito101/fc4-flags-api:1.0.0` (prod)  |     ~214 MB |        ~56 MB |

A imagem de produção é cerca de **2x menor** que a de dev - sem devDependencies, sem TypeScript/tsx, sem toolchain de build e sobre uma base sem shell/gerenciador de pacotes, bem abaixo do limite de 350 MB exigido.

## Decisões técnicas

### Imagem base de produção

Escolhida uma composição **distroless** (`gcr.io/distroless/cc-debian12:nonroot`, ~20 MB) com o binário oficial do Node.js copiado de `node:22.22.2-bookworm-slim` por cima (estágio `node-runtime`), em vez de usar diretamente as tags prontas `gcr.io/distroless/nodejs22-debian12`.

Motivo: ao rodar `docker scout cves` contra a tag `nodejs22-debian12:nonroot`, o Node embutido nela (22.22.0) continha a CVE crítica **CVE-2025-55130** (corrigida em 22.22.2), e a tag distroless ainda não havia sido republicada com o patch. Como a imagem `cc-debian12` já fornece exatamente as bibliotecas dinâmicas de que o binário do Node depende (`libc`, `libstdc++`, `libgcc`, `libm`, `libdl`, `libpthread` - verificado com `ldd`), copiar o Node de uma tag oficial já patcheada resolve a CVE sem abrir mão da superfície mínima do distroless (sem shell, sem `apt`/`apk`, usuário não-root nativo).

**Alternativa considerada e descartada:** `node:22-alpine`. Prós: menor esforço (nenhuma montagem manual de binário), boa maturidade/documentação, `apk` disponível para depuração. Contras decisivos para este caso: (1) traz um shell e um gerenciador de pacotes completos na imagem final, ampliando a superfície de ataque que o desafio pede para minimizar; (2) a base Alpine tem seu próprio histórico de CVEs em `busybox`/`musl`/`openssl` que precisariam ser monitorados à parte; (3) o tamanho final (~180 MB só de base) fica mais próximo do limite de 350 MB do que a composição distroless usada (~20 MB de base). A composição distroless entrega superfície de ataque menor e imagem menor, ao custo de exigir o estágio extra `node-runtime` - trade-off considerado favorável para produção.

### Estratégia de cache de build

- `RUN --mount=type=cache,target=/root/.npm` em todo `npm ci`, para os estágios `dev`, `build` e `prod-deps` - o cache do npm persiste entre builds mesmo quando a camada é invalidada, evitando novo download de pacotes da rede.
- Estágio `base` compartilhado copia **apenas** `package.json` e `package-lock.json` antes de qualquer outra instrução. Como o restante do código (`COPY . .`) só acontece depois do `npm ci`, alterar um arquivo em `src/` nunca invalida a camada de instalação de dependências - só uma mudança no `package.json`/lockfile dispara reinstalação.
- `prod-deps` roda `npm ci --omit=dev` isolado do estágio `build` (que precisa de `devDependencies` para compilar), então a imagem de produção nunca herda camadas com dependências de desenvolvimento.
- O estágio `node-runtime` e o `base` ficam completamente desacoplados: o Buildx só refaz o download da imagem `node:22.22.2-bookworm-slim` se o `ARG NODE_RUNTIME_VERSION` mudar.

## Como rodar (desenvolvimento)

```bash
cp .env.example .env
docker compose up
```

Isso sobe `db` (PostgreSQL com healthcheck), aplica as migrações automaticamente via serviço `migrate` (`condition: service_completed_successfully`) e só então inicia `app`. A API fica disponível em <http://localhost:3000> (`GET /flags` → 200).

**Hot reload com watch** (sync de `src/` sem rebuild, rebuild automático se `package.json` mudar):

```bash
docker compose watch
# ou: docker compose up --watch
```

**Cliente de administração do banco** (Adminer), somente sob demanda via profile `tools`:

```bash
docker compose --profile tools up -d
# http://localhost:8081 - Sistema: PostgreSQL, Servidor: db, Usuário/senha/banco: valores do .env
```

Verificar que o processo da aplicação não roda como root:

```bash
docker compose exec app id -u   # retorna 1000 (usuário "node")
```

## Como rodar (produção)

```bash
cp .env.example .env
docker compose -f compose.prod.yaml up -d
```

`compose.prod.yaml` não contém nenhuma instrução `build`: `app` e `migrate` usam a imagem já publicada `brito101/fc4-flags-api:1.0.0`. O serviço `migrate` roda a migração (`node dist/db/migrate.js`) e finaliza antes de `app` iniciar; `app` e `db` têm `restart: unless-stopped` e limites de CPU/memória; não há bind mount de código-fonte e os dados do Postgres ficam no volume nomeado `fc4-flags-db-data-prod`.

```bash
docker compose -f compose.prod.yaml ps
# app e db devem aparecer como "healthy"

curl -i http://localhost:3000/flags   # 200
```

## Segurança e supply chain

```bash
# Usuário não-root (a imagem já roda como uid 65532 por padrão da base distroless "nonroot")
docker image inspect brito101/fc4-flags-api:1.0.0 --format '{{.Config.User}}'

# Labels OCI exigidas
docker image inspect brito101/fc4-flags-api:1.0.0 --format '{{json .Config.Labels}}'

# HEALTHCHECK declarado na imagem
docker image inspect brito101/fc4-flags-api:1.0.0 --format '{{json .Config.Healthcheck}}'

# Plataformas, SBOM e provenance publicados junto da imagem
docker buildx imagetools inspect brito101/fc4-flags-api:1.0.0

# Encerramento gracioso: para em menos de 10s, sem aguardar o SIGKILL
time docker stop <container>
```

### Resumo do Docker Scout

Relatório completo em [`reports/scout-cves.txt`](reports/scout-cves.txt) (`docker scout cves brito101/fc4-flags-api:1.0.0`):

```text
vulnerabilities │ 0C  0H  1M  11L  21?
```

- **0 CRITICAL, 0 HIGH.** Não há CVEs HIGH nem CRITICAL sem correção a justificar - a única CVE CRITICAL detectada durante o desenvolvimento (CVE-2025-55130, no runtime Node embutido na tag distroless `nodejs22-debian12`) foi eliminada trocando a fonte do binário do Node para `node:22.22.2-bookworm-slim` (ver [Decisões técnicas](#decisões-técnicas)); confirmado com:

  ```bash
  docker scout cves --only-severity critical --only-fixed brito101/fc4-flags-api:1.0.0
  # ✓ 0 vulnerabilities found
  ```

- 1 MEDIUM (`CVE-2026-6791`, `glibc`) e 11 LOW, todas **sem correção disponível** na Debian 12 no momento do build (`Fixed version: not fixed`) - abaixo do limiar (HIGH/CRITICAL) que o desafio exige justificar, mantidas apenas como acompanhamento: futuras republicações da imagem (`docker buildx build --pull ...`) absorvem o patch assim que o Debian o disponibilizar, sem qualquer mudança de código.

## Validação

| Critério de aceite | Comando de verificação |
|---|---|
| Dockerfile único com estágios `dev`, `build`, `production` | `grep -E '^FROM .* AS (dev\|build\|production)' Dockerfile` |
| Nenhuma imagem com `latest`/sem tag | inspeção manual de `Dockerfile`, `compose.yaml`, `compose.prod.yaml` (todas as tags são fixadas) |
| `.dockerignore` exclui `node_modules`, `dist`, `.git`, `.env` | `cat .dockerignore` |
| `npm ci` usa cache de build | `grep -A1 'npm ci' Dockerfile` (`RUN --mount=type=cache,...`) |
| `docker build --target dev .` / `--target production .` concluem sem erro | `docker build --target dev . && docker build --target production .` |
| `cp .env.example .env && docker compose up` deixa API em `:3000`, `/flags` → 200 | `cp .env.example .env && docker compose up -d && curl -i http://localhost:3000/flags` |
| `db` com healthcheck, `app` com `condition: service_healthy` | `grep -A5 'healthcheck' compose.yaml`; `docker compose ps` |
| `docker compose watch`: sync em `src/`, rebuild em `package.json` | `docker compose watch` + editar `src/app.ts` (sync) e `package.json` (rebuild) |
| `docker compose --profile tools up -d` sobe Adminer em `:8081` | `docker compose --profile tools up -d && curl -I http://localhost:8081` |
| `docker compose exec app id -u` ≠ 0 | `docker compose exec app id -u` |
| `.env` fora do versionamento, `.env.example` versionado e funcional | `git check-ignore .env`; `cat .env.example` |
| `imagetools inspect` lista `linux/amd64` e `linux/arm64` | `docker buildx imagetools inspect brito101/fc4-flags-api:1.0.0` |
| `imagetools inspect` exibe attestations de SBOM e provenance | `docker buildx imagetools inspect brito101/fc4-flags-api:1.0.0 --format '{{json .SBOM}}'` / `--format '{{json .Provenance}}'` |
| Tag semver e `latest` apontam para o mesmo digest | `docker buildx imagetools inspect brito101/fc4-flags-api:1.0.0` vs `...:latest` (mesmo `Digest:`) |
| Tamanho ≤ 350 MB após `docker pull --platform linux/amd64` | `docker pull --platform linux/amd64 brito101/fc4-flags-api:1.0.0 && docker image ls brito101/fc4-flags-api` |
| `User` não-root, `HEALTHCHECK` e 4 labels OCI | `docker image inspect brito101/fc4-flags-api:1.0.0 --format '{{.Config.User}} {{json .Config.Healthcheck}} {{json .Config.Labels}}'` |
| Container fica `healthy` com banco acessível | `docker compose -f compose.prod.yaml up -d && docker compose -f compose.prod.yaml ps` |
| `docker stop` encerra em < 10s | `time docker stop <container>` |
| `reports/scout-cves.txt` com saída completa do Scout | `cat reports/scout-cves.txt` |
| Zero CRITICAL com correção disponível | `docker scout cves --only-severity critical --only-fixed brito101/fc4-flags-api:1.0.0` |
| CVEs HIGH/CRITICAL-sem-fix justificadas no README | seção [Segurança e supply chain](#segurança-e-supply-chain) (nenhuma encontrada) |
| `compose.prod.yaml` sem `build`, usa imagem pela tag semver | `grep -c 'build:' compose.prod.yaml` (0); `grep image: compose.prod.yaml` |
| `app`/`db` com restart policy e limites de CPU/memória | `docker inspect fc4-flags-api-prod-app-1 --format '{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}'` |
| Sem bind mount de código; dados do Postgres em volume nomeado | `docker inspect fc4-flags-api-prod-db-1 --format '{{json .Mounts}}'` |
| `cp .env.example .env && docker compose -f compose.prod.yaml up -d` → API em `:3000`, `/flags` → 200, `ps` mostra `healthy` | `cp .env.example .env && docker compose -f compose.prod.yaml up -d && curl -i http://localhost:3000/flags && docker compose -f compose.prod.yaml ps` |
| Código da aplicação não alterado | `git diff upstream/main -- src/ package.json package-lock.json tsconfig.json` (sem diferenças) |
| Nenhuma credencial hardcoded fora do `.env.example` | `grep -RniE 'password\|secret' Dockerfile compose.yaml compose.prod.yaml` (nenhum valor fixo, apenas `${VAR}`) |
