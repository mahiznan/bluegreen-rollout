// Baked in at build time by Vite from the VITE_* environment (see the Dockerfile).
export const config = {
  commit: import.meta.env.VITE_COMMIT || 'dev',
  gateway: import.meta.env.VITE_GATEWAY_URL || 'http://localhost:8080',
};
