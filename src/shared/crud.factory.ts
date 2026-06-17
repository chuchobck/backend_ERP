/**
 * ═══════════════════════════════════════════════════════════════
 *  crud.factory.ts — Genera rutas CRUD genéricas para cualquier
 *  modelo Prisma del sistema COMERCIAL.
 *
 *  Uso:
 *    import { crudRouter } from "../shared/crud.factory.js";
 *    const router = crudRouter("productos", {
 *      searchFields: ["pro_nombre", "pro_descripcion"],
 *      defaultInclude: { categoria: true },
 *    });
 * ═══════════════════════════════════════════════════════════════
 */
import { Router, Request, Response, NextFunction, RequestHandler } from "express";
import { prisma } from "./prisma.js";
import { ZodSchema } from "zod";

type PrismaModelName = keyof typeof prisma & string;

export interface CrudOptions {
  createMiddleware?: RequestHandler | RequestHandler[];
  updateMiddleware?: RequestHandler | RequestHandler[];
  deleteMiddleware?: RequestHandler | RequestHandler[];
  /** Campos para búsqueda textual via ?q=... */
  searchFields?: string[];
  /** Include por defecto en findMany / findUnique */
  defaultInclude?: Record<string, unknown>;
  /** Zod schema para CREATE */
  createSchema?: ZodSchema;
  /** Zod schema para UPDATE */
  updateSchema?: ZodSchema;
  /** Campo PK si no es 'id' (ej: 'id_producto') */
  pkField?: string;
  /** PKs compuestas: ['id_compra', 'id_producto'] */
  compositeKey?: string[];
  /** Campo de estado para soft-delete (ej: 'estado_prod') */
  statusField?: string;
  /** Valor activo / inactivo del campo de estado */
  activeValue?: string;
  inactiveValue?: string;
  /** Ordenamiento por defecto */
  defaultOrderBy?: Record<string, "asc" | "desc">;
}

function getDelegate(model: string) {
  return (prisma as any)[model];
}

/** Parsea PK compuesta desde la URL: /compras~PRD0001 → { id_compra: "compras", id_producto: "PRD0001" } */
function parsePk(raw: string, opts: CrudOptions): Record<string, string | number> {
  if (opts.compositeKey) {
    const parts = raw.split("~");
    const where: Record<string, string> = {};
    opts.compositeKey.forEach((k, i) => {
      where[k] = parts[i] ?? "";
    });
    return where;
  }
  return { [opts.pkField ?? "id"]: raw };
}

export function crudRouter(model: string, opts: CrudOptions = {}): Router {
  const router = Router();
  const delegate = getDelegate(model);

  // ── GET /  — lista paginada con búsqueda ──────────────────────
  router.get("/", async (req: Request, res: Response, next: NextFunction) => {
    try {
      const page = Math.max(1, parseInt(req.query.page as string) || 1);
      const limit = Math.min(100, Math.max(1, parseInt(req.query.limit as string) || 25));
      const skip = (page - 1) * limit;
      const q = (req.query.q as string)?.trim();

      let where: any = {};

      // Búsqueda textual
      if (q && opts.searchFields?.length) {
        where.OR = opts.searchFields.map((f) => ({
          [f]: { contains: q, mode: "insensitive" },
        }));
      }

      // Filtro por estado
      if (req.query.estado && opts.statusField) {
        where[opts.statusField] = (req.query.estado as string).toUpperCase();
      }

      // Filtros genéricos via query params (campo=valor)
      for (const [key, val] of Object.entries(req.query)) {
        if (["page", "limit", "q", "estado", "orderBy", "order"].includes(key)) continue;
        if (typeof val === "string") where[key] = val;
      }

      const orderBy = opts.defaultOrderBy ?? { [opts.pkField ?? "id"]: "asc" as const };

      const [data, total] = await Promise.all([
        delegate.findMany({
          where,
          skip,
          take: limit,
          orderBy,
          ...(opts.defaultInclude ? { include: opts.defaultInclude } : {}),
        }),
        delegate.count({ where }),
      ]);

      res.json({
        data,
        meta: { page, limit, total, totalPages: Math.ceil(total / limit) },
      });
    } catch (err) {
      next(err);
    }
  });

  // ── GET /:id  — detalle ───────────────────────────────────────
  router.get("/:id", async (req: Request, res: Response, next: NextFunction) => {
    try {
      const pk = parsePk(String(req.params.id), opts);
      const where = opts.compositeKey
        ? { [opts.compositeKey.join("_")]: pk }
        : pk;

      const record = await delegate.findUnique({
        where,
        ...(opts.defaultInclude ? { include: opts.defaultInclude } : {}),
      });

      if (!record) return res.status(404).json({ error: "Registro no encontrado" });
      res.json(record);
    } catch (err) {
      next(err);
    }
  });

  // ── POST /  — crear ──────────────────────────────────────────
  const createHandlers = Array.isArray(opts.createMiddleware)
    ? opts.createMiddleware
    : opts.createMiddleware
      ? [opts.createMiddleware]
      : [];

  router.post("/", ...createHandlers, async (req: Request, res: Response, next: NextFunction) => {
    try {
      let body = req.body;
      if (opts.createSchema) {
        const parsed = opts.createSchema.safeParse(body);
        if (!parsed.success) {
          return res.status(400).json({ error: "Validación fallida", details: parsed.error.flatten() });
        }
        body = parsed.data;
      }
      const record = await delegate.create({ data: body });
      res.status(201).json(record);
    } catch (err) {
      next(err);
    }
  });

  // ── PUT /:id  — actualizar ────────────────────────────────────
  const updateHandlers = Array.isArray(opts.updateMiddleware)
    ? opts.updateMiddleware
    : opts.updateMiddleware
      ? [opts.updateMiddleware]
      : [];

  router.put("/:id", ...updateHandlers, async (req: Request, res: Response, next: NextFunction) => {
    try {
      let body = req.body;
      if (opts.updateSchema) {
        const parsed = opts.updateSchema.safeParse(body);
        if (!parsed.success) {
          return res.status(400).json({ error: "Validación fallida", details: parsed.error.flatten() });
        }
        body = parsed.data;
      }
      const pk = parsePk(String(req.params.id), opts);
      const where = opts.compositeKey
        ? { [opts.compositeKey.join("_")]: pk }
        : pk;

      const record = await delegate.update({ where, data: body });
      res.json(record);
    } catch (err) {
      next(err);
    }
  });

  // ── DELETE /:id  — soft delete (o hard si no hay statusField) ─
  const deleteHandlers = Array.isArray(opts.deleteMiddleware)
    ? opts.deleteMiddleware
    : opts.deleteMiddleware
      ? [opts.deleteMiddleware]
      : [];

  router.delete("/:id", ...deleteHandlers, async (req: Request, res: Response, next: NextFunction) => {
    try {
      const pk = parsePk(String(req.params.id), opts);
      const where = opts.compositeKey
        ? { [opts.compositeKey.join("_")]: pk }
        : pk;

      if (opts.statusField) {
        await delegate.update({
          where,
          data: { [opts.statusField]: opts.inactiveValue ?? "INA" },
        });
        res.json({ message: "Registro desactivado" });
      } else {
        await delegate.delete({ where });
        res.json({ message: "Registro eliminado" });
      }
    } catch (err) {
      next(err);
    }
  });

  return router;
}

// ── Helper: ejecutar Stored Procedures via $queryRawUnsafe ──────
export async function callSP(name: string, ...args: unknown[]) {
  const placeholders = args.map((_, i) => `$${i + 1}`).join(", ");
  return prisma.$queryRawUnsafe(`CALL comercial.${name}(${placeholders})`, ...args);
}

// ── Helper: ejecutar funciones que retornan REFCURSOR ───────────
export async function callFnRefcursor(fnName: string, ...args: unknown[]) {
  return prisma.$transaction(async (tx) => {
    const placeholders = args.map((_, i) => `$${i + 1}`).join(", ");
    await tx.$queryRawUnsafe(
      `SELECT comercial.${fnName}(${placeholders})`,
      ...args
    );
    const rows = await tx.$queryRawUnsafe(`FETCH ALL FROM "ref_result"`);
    return rows;
  });
}
