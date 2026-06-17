import "dotenv/config";

export const env = {
  PORT: parseInt(process.env.PORT ?? "3000"),
  NODE_ENV: process.env.NODE_ENV ?? "development",
  JWT_SECRET: process.env.JWT_SECRET ?? "dev-secret-change-me",
  JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN ?? "7d",
  CORS_ORIGINS: (process.env.CORS_ORIGINS ?? "http://localhost:5173")
    .split(",")
    .map((o) => o.trim()),
  ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY ?? "",
  VOYAGE_API_KEY: process.env.VOYAGE_API_KEY ?? "",
  AZURE_STORAGE_CONNECTION_STRING: process.env.AZURE_STORAGE_CONNECTION_STRING ?? "",
  AZURE_BLOB_CONTAINER: process.env.AZURE_BLOB_CONTAINER ?? "",
} as const;
