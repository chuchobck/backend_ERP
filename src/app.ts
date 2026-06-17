import express from "express";
import cors from "cors";
import { env } from "./config/env.js";
import { errorHandler } from "./middleware/errorHandler.js";
import { authGuard } from "./middleware/auth.js";

// ── Module routers ──────────────────────────────────────────────
import authRoutes from "./modules/auth/auth.routes.js";
import coreRoutes from "./modules/core/core.routes.js";
import tiendaRoutes from "./modules/tienda/tienda.routes.js";
import comprasRoutes from "./modules/compras/compras.routes.js";
import inventariosRoutes from "./modules/inventarios/inventarios.routes.js";
import ventasRoutes from "./modules/ventas/ventas.routes.js";
import contabilidadRoutes from "./modules/contabilidad/contabilidad.routes.js";
import thRoutes from "./modules/talento-humano/th.routes.js";
import reportesRoutes from "./modules/reportes/reportes.routes.js";
import trazabilidadRoutes from "./modules/trazabilidad/trazabilidad.routes.js";

export function createApp() {
  const app = express();

  // ── Middleware global ───────────────────────────────────────────
  app.use(cors({ origin: env.CORS_ORIGINS, credentials: true }));
  app.use(express.json({ limit: "5mb" }));

  // ── Health check ────────────────────────────────────────────────
  app.get("/api/health", (_req, res) => {
    res.json({ status: "ok", timestamp: new Date().toISOString() });
  });

  // ── Auth (público) ──────────────────────────────────────────────
  app.use("/api/auth", authRoutes);

  // ── Tienda ecommerce (público) ───────────────────────────────
  app.use("/api/tienda", tiendaRoutes);

  // ── Core / Catálogos — lectura pública, escritura protegida ───
  app.use("/api/core", coreRoutes);

  // ── Rutas protegidas — auth global a partir de aquí ───────────
  app.use("/api", authGuard);

  // ── Módulo 1: Compras ─────────────────────────────────────────
  app.use("/api/compras", comprasRoutes);

  // ── Módulo 2: Inventarios ─────────────────────────────────────
  app.use("/api/inventarios", inventariosRoutes);

  // ── Módulo 3: Ventas ──────────────────────────────────────────
  app.use("/api/ventas", ventasRoutes);

  // ── Módulo 4: Contabilidad ────────────────────────────────────
  app.use("/api/contabilidad", contabilidadRoutes);

  // ── Módulo 5: Talento Humano ──────────────────────────────────
  app.use("/api/th", thRoutes);

  // ── Módulo 6: Reportes y Analítica ────────────────────────────
  app.use("/api/reportes", reportesRoutes);

  // ── Módulo 7: Trazabilidad blockchain ─────────────────────────
  app.use("/api/trazabilidad", trazabilidadRoutes);

  // ── Error handler ─────────────────────────────────────────────
  app.use(errorHandler);

  return app;
}
