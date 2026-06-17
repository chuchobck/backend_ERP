/**
 * ═══════════════════════════════════════════════════════════════
 *  trazabilidad.routes.ts   → se monta en /api/trazabilidad
 * ═══════════════════════════════════════════════════════════════
 */
import { Router, Request, Response, NextFunction } from "express";
import { machineContext } from "../../middleware/machine.js";
import * as traza from "./trazabilidad.service.js";

const router = Router();
router.use(machineContext); // toda ruta tiene req.machine disponible

// ── Registrar un evento manual ──────────────────────────────────
//  Body: { id_producto, tipo_evento, id_referencia?, id_proveedor?, id_bodega?,
//          cantidad?, costo_unit?, datos?, id_empleado? }
router.post("/evento", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const out = await traza.registrarEvento({ ...req.body, machine: req.machine! });
    res.status(201).json({ message: "Evento registrado en la cadena", bloque: out });
  } catch (err) { next(err); }
});

// ── Cadena completa de un producto ──────────────────────────────
router.get("/producto/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const cadena = await traza.getCadena(req.params.id);
    res.json({ id_producto: req.params.id, cadena });
  } catch (err) { next(err); }
});

// ── Verificar integridad de la cadena ───────────────────────────
router.get("/producto/:id/verificar", async (req: Request, res: Response, next: NextFunction) => {
  try {
    res.json(await traza.verificar(req.params.id));
  } catch (err) { next(err); }
});

// ── Trazabilidad por proveedor ──────────────────────────────────
router.get("/proveedor/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    res.json({ id_proveedor: req.params.id, compras: await traza.porProveedor(req.params.id) });
  } catch (err) { next(err); }
});

export default router;
