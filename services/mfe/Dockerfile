# ---- Stage 1: build the static files ----
FROM node:22-alpine AS build
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Values baked into the bundle. Passed by scripts/release.sh as BuildConfig build args.
ARG GIT_COMMIT=unknown
ARG VITE_GATEWAY_URL=http://localhost:8080
ENV VITE_COMMIT=${GIT_COMMIT}
ENV VITE_GATEWAY_URL=${VITE_GATEWAY_URL}
RUN npm run build

# ---- Stage 2: serve it (non-root, port 8080; works with OpenShift's random UID) ----
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/dist /usr/share/nginx/html
# So that `oc exec ... printenv GIT_COMMIT` can verify the running release, like the other services.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
EXPOSE 8080
