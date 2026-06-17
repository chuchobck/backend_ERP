/**
 * ═══════════════════════════════════════════════════════════════
 *  MÓDULO 6 — REPORTES Y ANALÍTICA
 *  4 endpoints analíticos que cruzan datos de múltiples módulos:
 *
 *  1. /top-ventas        → Barras: rendimiento por categoría
 *  2. /stock-distribucion → Pastel: distribución de inventario
 *  3. /flujo-caja        → Líneas: ingresos vs egresos temporal
 *  4. /densidad-regional → Mapa: concentración de facturación
 * ═══════════════════════════════════════════════════════════════
 */
import { Router, Request, Response, NextFunction } from "express";
import { prisma } from "../../shared/prisma.js";

const router = Router();

// ─────────────────────────────────────────────────────────────────
//  1. TOP VENTAS POR CATEGORÍA (Gráfico de Barras)
//     Cruza: factura_det × productos × categorias
// ─────────────────────────────────────────────────────────────────
router.get("/top-ventas", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const limit = Math.min(50, parseInt(req.query.limit as string) || 10);
    const desde = req.query.desde as string || null;
    const hasta = req.query.hasta as string || null;

    const rows = await prisma.$queryRawUnsafe(`
      SELECT
        c.id_categoria,
        c.cat_descripcion                        AS categoria,
        COUNT(DISTINCT fd.id_factura)             AS num_facturas,
        SUM(fd.fad_cantidad)                      AS qty_vendida,
        SUM(fd.fad_subtotal)                      AS total_vendido
      FROM comercial.factura_det fd
      JOIN comercial.productos   p  ON p.id_producto  = fd.id_producto
      JOIN comercial.categorias  c  ON c.id_categoria = p.id_categoria
      JOIN comercial.facturas    f  ON f.id_factura   = fd.id_factura
      WHERE f.estado_fac = 'APR'
        ${desde ? `AND f.fac_fecha >= $1::TIMESTAMP` : "AND TRUE"}
        ${hasta ? `AND f.fac_fecha <= ${desde ? "$2" : "$1"}::TIMESTAMP` : "AND TRUE"}
      GROUP BY c.id_categoria, c.cat_descripcion
      ORDER BY total_vendido DESC
      LIMIT ${limit}
    `, ...(desde ? [desde] : []), ...(hasta ? [hasta] : []));

    res.json({ chart: "bar", title: "Top Ventas por Categoría", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  1b. TOP VENTAS POR VENDEDOR
// ─────────────────────────────────────────────────────────────────
router.get("/top-vendedores", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRaw`
      SELECT
        v.id_vendedor,
        e.emp_apellidos || ' ' || e.emp_nombres   AS vendedor,
        COUNT(f.id_factura)                        AS num_facturas,
        COALESCE(SUM(f.fac_total), 0)              AS total_vendido,
        v.ven_meta_mes                             AS meta,
        v.ven_comision                             AS comision_pct
      FROM comercial.vendedores v
      JOIN comercial.empleados  e ON e.id_empleado = v.id_vendedor
      LEFT JOIN comercial.facturas f ON f.id_vendedor = v.id_vendedor AND f.estado_fac = 'APR'
      WHERE v.estado_ven = 'ACT'
      GROUP BY v.id_vendedor, e.emp_apellidos, e.emp_nombres, v.ven_meta_mes, v.ven_comision
      ORDER BY total_vendido DESC
    `;
    res.json({ chart: "bar", title: "Rendimiento de Vendedores", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  2. DISTRIBUCIÓN DE STOCK POR BODEGA (Gráfico de Pastel)
//     Cruza: stock_bodega × bodegas
// ─────────────────────────────────────────────────────────────────
router.get("/stock-distribucion", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRaw`
      SELECT
        b.id_bodega,
        b.bod_nombre                     AS bodega,
        SUM(sb.stk_cantidad)::float8              AS total_stock,
        SUM(sb.stk_disponible)::float8            AS stock_disponible,
        SUM(sb.stk_reservado)::float8             AS stock_reservado,
        COUNT(sb.id_producto)::int                AS num_productos,
        SUM(sb.stk_cantidad * sb.stk_costo_prom)::float8 AS valor_inventario
      FROM comercial.stock_bodega sb
      JOIN comercial.bodegas      b ON b.id_bodega = sb.id_bodega
      WHERE b.estado_bod = 'ACT'
      GROUP BY b.id_bodega, b.bod_nombre
      ORDER BY total_stock DESC
    `;
    res.json({ chart: "pie", title: "Distribución de Stock por Bodega", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  3. FLUJO DE CAJA — INGRESOS VS EGRESOS (Gráfico de Líneas)
//     Cruza: facturas (ingresos) vs compras (egresos) por fecha
// ─────────────────────────────────────────────────────────────────
router.get("/flujo-caja", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const agrupacion = req.query.agrupacion === "dia" ? "DAY" : "MONTH";

    const rows = await prisma.$queryRaw`
      WITH ingresos AS (
        SELECT
          DATE_TRUNC(${agrupacion}, fac_fecha) AS periodo,
          SUM(fac_total) AS total_ingresos
        FROM comercial.facturas
        WHERE estado_fac = 'APR'
        GROUP BY 1
      ),
      egresos AS (
        SELECT
          DATE_TRUNC(${agrupacion}, oc_fecha) AS periodo,
          SUM(oc_total) AS total_egresos
        FROM comercial.compras
        WHERE estado_oc = 'APR'
        GROUP BY 1
      )
      SELECT
        COALESCE(i.periodo, e.periodo)           AS periodo,
        COALESCE(i.total_ingresos, 0)            AS ingresos,
        COALESCE(e.total_egresos, 0)             AS egresos,
        COALESCE(i.total_ingresos, 0) - COALESCE(e.total_egresos, 0) AS flujo_neto
      FROM ingresos i
      FULL OUTER JOIN egresos e ON i.periodo = e.periodo
      ORDER BY periodo
    `;
    res.json({ chart: "line", title: "Flujo de Caja: Ingresos vs Egresos", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  4. DENSIDAD REGIONAL DE FACTURACIÓN (Mapa Coroplético)
//     Cruza: facturas × clientes × ciudades × provincias
// ─────────────────────────────────────────────────────────────────
router.get("/densidad-regional", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRaw`
      SELECT
        pr.id_provincia,
        pr.prv_descripcion          AS provincia,
        ci.id_ciudad,
        ci.ciu_descripcion          AS ciudad,
        COUNT(f.id_factura)         AS num_facturas,
        COUNT(DISTINCT f.id_cliente) AS num_clientes,
        COALESCE(SUM(f.fac_total), 0)  AS total_facturado
      FROM comercial.facturas  f
      JOIN comercial.clientes  cl ON cl.id_cliente  = f.id_cliente
      JOIN comercial.ciudades  ci ON ci.id_ciudad   = cl.id_ciudad
      JOIN comercial.provincias pr ON pr.id_provincia = ci.id_provincia
      WHERE f.estado_fac = 'APR'
      GROUP BY pr.id_provincia, pr.prv_descripcion,
               ci.id_ciudad, ci.ciu_descripcion
      ORDER BY total_facturado DESC
    `;
    res.json({ chart: "geo", title: "Densidad Regional de Facturación", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  EXTRA: Cuotas en mora (vista v_cuotas_mora)
// ─────────────────────────────────────────────────────────────────
router.get("/cuotas-mora", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const soloMorosos = req.query.morosos === "true";
    const rows = await prisma.$queryRawUnsafe(`
      SELECT v.*, f.fac_numero_sri, c.cli_nombre
      FROM comercial.v_cuotas_mora v
      JOIN comercial.facturas      f ON f.id_factura = v.id_factura
      JOIN comercial.clientes      c ON c.id_cliente = f.id_cliente
      ${soloMorosos ? "WHERE v.cuo_dias_mora > 0 AND v.estado_cuo = 'PEN'" : ""}
      ORDER BY v.cuo_dias_mora DESC
      LIMIT 200
    `);
    res.json({ title: "Cartera en Mora", data: rows });
  } catch (err) { next(err); }
});

// ─────────────────────────────────────────────────────────────────
//  EXTRA: Dashboard resumen general
// ─────────────────────────────────────────────────────────────────
router.get("/dashboard", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const [ventas, compras, productos, clientes, empleados] = await Promise.all([
      prisma.$queryRaw`
        SELECT COUNT(*) AS total, COALESCE(SUM(fac_total), 0) AS monto
        FROM comercial.facturas WHERE estado_fac = 'APR'`,
      prisma.$queryRaw`
        SELECT COUNT(*) AS total, COALESCE(SUM(oc_total), 0) AS monto
        FROM comercial.compras WHERE estado_oc = 'APR'`,
      prisma.$queryRaw`
        SELECT COUNT(*) AS total FROM comercial.productos WHERE estado_prod = 'ACT'`,
      prisma.$queryRaw`
        SELECT COUNT(*) AS total FROM comercial.clientes WHERE estado_cli = 'ACT'`,
      prisma.$queryRaw`
        SELECT COUNT(*) AS total FROM comercial.empleados WHERE estado_emp = 'ACT'`,
    ]);

    res.json({
      ventas: (ventas as any[])[0],
      compras: (compras as any[])[0],
      productos_activos: (productos as any[])[0]?.total,
      clientes_activos: (clientes as any[])[0]?.total,
      empleados_activos: (empleados as any[])[0]?.total,
    });
  } catch (err) { next(err); }
});

export default router;
