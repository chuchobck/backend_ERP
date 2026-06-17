/**
 * ═══════════════════════════════════════════════════════════════
 *  MÓDULO TIENDA (E-COMMERCE) — público, sin auth
 *
 *  Lee del MISMO modelo de datos (productos, categorías, stock) y
 *  el checkout crea una factura en estado 'ABI' (abierta) + su
 *  detalle. El backoffice luego la aprueba (lo que dispara el
 *  movimiento de stock vía tus SPs). Separación limpia:
 *    tienda  → crea pedido (factura ABI)
 *    backoffice → aprueba (factura APR)
 * ═══════════════════════════════════════════════════════════════
 */
import { Router, Request, Response, NextFunction } from "express";
import { prisma } from "../../shared/prisma.js";
import { z } from "zod";

const router = Router();
const IVA = 0.15; // Ecuador 2024+

// ─────────────────────────────────────────────────────────────────
//  GET /tienda/categorias  — con conteo de productos activos
// ─────────────────────────────────────────────────────────────────
router.get("/categorias", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRaw`
      SELECT c.id_categoria, c.cat_descripcion,
             COUNT(p.id_producto)::int AS num_productos
      FROM comercial.categorias c
      LEFT JOIN comercial.productos p
        ON p.id_categoria = c.id_categoria AND p.estado_prod = 'ACT'
      GROUP BY c.id_categoria, c.cat_descripcion
      HAVING COUNT(p.id_producto) > 0
      ORDER BY num_productos DESC
      LIMIT 60
    `;
    res.json(rows);
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  GET /tienda/productos  — catálogo público
//  ?q= &categoria= &page= &limit= &orden=(precio_asc|precio_desc|nombre)
// ─────────────────────────────────────────────────────────────────
router.get("/productos", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const page = Math.max(1, parseInt(req.query.page as string) || 1);
    const limit = Math.min(48, Math.max(1, parseInt(req.query.limit as string) || 24));
    const offset = (page - 1) * limit;
    const q = (req.query.q as string)?.trim() || null;
    const categoria = (req.query.categoria as string)?.trim() || null;
    const orden = (req.query.orden as string) || "nombre";

    const orderBy =
      orden === "precio_asc" ? "p.pro_precio_venta ASC"
      : orden === "precio_desc" ? "p.pro_precio_venta DESC"
      : "p.pro_nombre ASC";

    // Productos activos + stock total (sumado entre bodegas)
    const where: string[] = ["p.estado_prod = 'ACT'", "p.pro_precio_venta > 0"];
    const params: unknown[] = [];
    if (q) { params.push(`%${q}%`); where.push(`(p.pro_nombre ILIKE $${params.length} OR p.pro_descripcion ILIKE $${params.length})`); }
    if (categoria) { params.push(categoria); where.push(`p.id_categoria = $${params.length}`); }
    const whereSql = where.join(" AND ");

    const dataParams = [...params, limit, offset];
    const rows = await prisma.$queryRawUnsafe(`
      SELECT
        p.id_producto, p.pro_nombre, p.pro_descripcion,
        p.pro_precio_venta, p.id_categoria, c.cat_descripcion,
        p.fk_pro_um_venta,
        COALESCE((SELECT SUM(sb.stk_disponible) FROM comercial.stock_bodega sb
                  WHERE sb.id_producto = p.id_producto), 0) AS stock
      FROM comercial.productos p
      JOIN comercial.categorias c ON c.id_categoria = p.id_categoria
      WHERE ${whereSql}
      ORDER BY ${orderBy}
      LIMIT $${params.length + 1} OFFSET $${params.length + 2}
    `, ...dataParams);

    const totalRows = await prisma.$queryRawUnsafe<{ total: bigint }[]>(`
      SELECT COUNT(*)::int AS total FROM comercial.productos p WHERE ${whereSql}
    `, ...params);
    const total = Number((totalRows as any[])[0]?.total ?? 0);

    res.json({
      data: rows,
      meta: { page, limit, total, totalPages: Math.ceil(total / limit) },
    });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  GET /tienda/productos/:id  — detalle
// ─────────────────────────────────────────────────────────────────
router.get("/productos/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRawUnsafe(`
      SELECT
        p.id_producto, p.pro_nombre, p.pro_descripcion,
        p.pro_precio_venta, p.id_categoria, c.cat_descripcion,
        p.fk_pro_um_venta, um.um_descripcion AS unidad,
        COALESCE((SELECT SUM(sb.stk_disponible) FROM comercial.stock_bodega sb
                  WHERE sb.id_producto = p.id_producto), 0) AS stock
      FROM comercial.productos p
      JOIN comercial.categorias c ON c.id_categoria = p.id_categoria
      LEFT JOIN comercial.unidades_medidas um ON um.id_unidad_medida = p.fk_pro_um_venta
      WHERE p.id_producto = $1 AND p.estado_prod = 'ACT'
      LIMIT 1
    `, req.params.id);
    const prod = (rows as any[])[0];
    if (!prod) return res.status(404).json({ error: "Producto no encontrado" });
    res.json(prod);
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  POST /tienda/checkout  — crea pedido (cliente + factura ABI + detalle)
// ─────────────────────────────────────────────────────────────────
const checkoutSchema = z.object({
  cliente: z.object({
    nombre: z.string().min(3).max(80),
    ruc_ced: z.string().min(10).max(13),
    celular: z.string().min(7).max(10),
    email: z.string().email().optional().nullable(),
    direccion: z.string().min(3).max(120),
    id_ciudad: z.string().length(3),
    tipo: z.enum(["JUR", "NAT"]).default("NAT"),
  }),
  forma_pago: z.string().length(3).default("EFE"),
  items: z.array(z.object({
    id_producto: z.string().length(7),
    cantidad: z.coerce.number().positive(),
    precio_unit: z.coerce.number().nonnegative(),
    id_unidad_medida: z.string().length(3),
  })).min(1),
});

/** Genera el siguiente ID secuencial con prefijo (namespace web, sin colisión) */
async function nextId(prefix: string, table: string, col: string, width: number): Promise<string> {
  const rows = await prisma.$queryRawUnsafe<{ n: number }[]>(`
    SELECT COALESCE(MAX(CAST(SUBSTRING(${col} FROM ${prefix.length + 1}) AS INTEGER)), 0) + 1 AS n
    FROM comercial.${table}
    WHERE ${col} LIKE '${prefix}%' AND SUBSTRING(${col} FROM ${prefix.length + 1}) ~ '^[0-9]+$'
  `);
  const n = rows[0]?.n ?? 1;
  return prefix + String(n).padStart(width, "0");
}

router.post("/checkout", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const parsed = checkoutSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: "Datos inválidos", details: parsed.error.flatten() });
    }
    const { cliente, forma_pago, items } = parsed.data;

    const result = await prisma.$transaction(async (tx) => {
      // 1) Cliente: buscar por RUC/cédula o crear (namespace 'WC')
      let cli = await tx.clientes.findUnique({ where: { cli_ruc_ced: cliente.ruc_ced } });
      if (!cli) {
        const idCliente = await nextId("WC", "clientes", "id_cliente", 5);
        cli = await tx.clientes.create({
          data: {
            id_cliente: idCliente,
            cli_nombre: cliente.nombre,
            cli_ruc_ced: cliente.ruc_ced,
            cli_celular: cliente.celular,
            cli_email: cliente.email ?? null,
            cli_direccion: cliente.direccion,
            id_ciudad: cliente.id_ciudad,
            cli_tipo: cliente.tipo,
            estado_cli: "ACT",
          },
        });
      }

      // 2) Vendedor por defecto (canal web): primer vendedor activo
      const vend = await tx.vendedores.findFirst({ where: { estado_ven: "ACT" } });
      if (!vend) throw Object.assign(new Error("No hay vendedor configurado para el canal web"), { code: "NO_VENDOR" });

      // 3) Totales
      const subtotal = items.reduce((s, it) => s + it.precio_unit * it.cantidad, 0);
      const iva = +(subtotal * IVA).toFixed(2);

      // 4) Factura (ABI) + número SRI (serie web 009-001)
      const idFactura = await nextId("W", "facturas", "id_factura", 6);
      const sriRows = await tx.$queryRawUnsafe<{ n: number }[]>(`
        SELECT COALESCE(MAX(CAST(SUBSTRING(fac_numero_sri FROM 9) AS INTEGER)), 0) + 1 AS n
        FROM comercial.facturas WHERE fac_numero_sri LIKE '009-001-%'
      `);
      const sriNum = String(sriRows[0]?.n ?? 1).padStart(9, "0");

      const factura = await tx.facturas.create({
        data: {
          id_factura: idFactura,
          fac_numero_sri: `009-001-${sriNum}`,
          id_cliente: cli.id_cliente,
          id_vendedor: vend.id_vendedor,
          id_forma_pago: forma_pago,
          fac_descripcion: "Pedido web (tienda en línea)",
          fac_subtotal: subtotal,
          fac_descuento: 0,
          fac_iva: iva,
          fac_ice: 0,
          estado_fac: "ABI",
        },
      });

      // 5) Detalle
      await tx.factura_det.createMany({
        data: items.map((it, i) => ({
          id_factura: idFactura,
          fad_linea: i + 1,
          id_producto: it.id_producto,
          id_unidad_medida: it.id_unidad_medida,
          fad_cantidad: it.cantidad,
          fad_precio_unit: it.precio_unit,
          fad_descuento_ln: 0,
          estado_fad: "ABI",
        })),
      });

      return { id_factura: idFactura, numero_sri: factura.fac_numero_sri, subtotal, iva, total: subtotal + iva, cliente: cli.cli_nombre };
    });

    res.status(201).json({ message: "Pedido creado correctamente", pedido: result });
  } catch (err) { next(err); }
});

export default router;
