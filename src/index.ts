import { createApp } from "./app.js";
import { env } from "./config/env.js";
import { prisma } from "./shared/prisma.js";

// PostgreSQL devuelve COUNT/SUM como BigInt; JSON.stringify no lo soporta por defecto
(BigInt.prototype as any).toJSON = function () { return this.toString(); };

async function main() {
  await prisma.$connect();
  console.log("✅ PostgreSQL conectado");

  const app = createApp();

  app.listen(env.PORT, () => {
    console.log(`
╔═══════════════════════════════════════════════════╗
║  🚀  COMERCIAL API — v1.0.0                      ║
║  📡  http://localhost:${env.PORT}                     ║
║  🔧  Entorno: ${env.NODE_ENV.padEnd(33)}║
╚═══════════════════════════════════════════════════╝

  Rutas disponibles:
  ──────────────────
  GET  /api/health
  POST /api/auth/login

  /api/core/*           Provincias, Ciudades, Departamentos, Roles, Categorías, UM
  /api/compras/*        Proveedores, Productos, Compras, Proxoc, Recepciones
  /api/inventarios/*    Bodegas, Perchas, Stock, Ajustes, Entregas, Movimientos
  /api/ventas/*         Clientes, Vendedores, Facturas, Devoluciones, Cuotas
  /api/contabilidad/*   Cuentas, Asientos, Partidas, Auditoría
  /api/th/*             Empleados, Rol Pagos, Cargas Familiares, Asistencias
  /api/reportes/*       Dashboard, Top Ventas, Stock, Flujo Caja, Densidad
    `);
  });
}

main().catch((err) => {
  console.error("❌ Error al iniciar:", err);
  process.exit(1);
});
