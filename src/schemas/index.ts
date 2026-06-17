/**
 * ═══════════════════════════════════════════════════════════════
 *  Zod Schemas — COMERCIAL
 *  Validaciones de entrada para CREATE y UPDATE por módulo.
 *  Los campos GENERATED se omiten (los calcula PG).
 * ═══════════════════════════════════════════════════════════════
 */
import { z } from "zod";

// ── Helpers ─────────────────────────────────────────────────────
const char = (n: number) => z.string().length(n);
const charOpt = (n: number) => z.string().length(n).optional();
const estado3 = (vals: [string, ...string[]]) => z.enum(vals).default(vals[0]);
const cedula = z.string().refine((v) => v.length === 10 || v.length === 13, "Cédula (10) o RUC (13)");
const email = z.string().email().optional().nullable();
const decimal = z.coerce.number().nonnegative();
const posInt = z.coerce.number().int().positive();

// ═══════ MÓDULO 0 — CORE ═══════════════════════════════════════

export const provinciaCreate = z.object({
  id_provincia: char(3),
  prv_descripcion: z.string().max(30),
});
export const ciudadCreate = z.object({
  id_ciudad: char(3),
  ciu_descripcion: z.string().max(30),
  id_provincia: char(3),
});
export const departamentoCreate = z.object({
  id_departamento: char(3),
  dep_descripcion: z.string().max(30),
  dep_presupuesto: decimal.default(0),
});
export const rolCreate = z.object({
  id_rol: char(3),
  rol_descripcion: z.string().max(30),
});
export const categoriaCreate = z.object({
  id_categoria: char(3),
  cat_descripcion: z.string().max(30),
});
export const unidadMedidaCreate = z.object({
  id_unidad_medida: char(3),
  um_descripcion: z.string().max(20),
});

// ═══════ MÓDULO 1 — COMPRAS ════════════════════════════════════

export const proveedorCreate = z.object({
  id_proveedor: char(7),
  prv_nombre: z.string().max(40),
  prv_ruc_ced: cedula,
  prv_telefono: z.string().max(10).optional().nullable(),
  prv_celular: z.string().max(10).optional().nullable(),
  prv_mail: email,
  id_ciudad: char(3),
  prv_direccion: z.string().max(60).optional().nullable(),
  prv_tipo: z.enum(["JUR", "NAT"]),
  estado_prv: estado3(["ACT", "INA"]),
});

export const productoCreate = z.object({
  id_producto: char(7),
  id_categoria: char(3),
  pro_nombre: z.string().max(40),
  pro_descripcion: z.string().max(100).optional().nullable(),
  fk_pro_um_compra: char(3),
  fk_pro_um_venta: char(3),
  pro_valor_compra: decimal.default(0),
  pro_precio_venta: decimal.default(0),
  pro_saldo_inicial: z.coerce.number().int().nonnegative().default(0),
  estado_prod: estado3(["ACT", "INA"]),
});

export const compraCreate = z.object({
  id_compra: char(7),
  id_proveedor: char(7),
  id_descuento: charOpt(3).nullable(),
  id_empleado: char(7),
  id_departamento: char(3),
  oc_fecha_entrega: z.coerce.date(),
  oc_subtotal: decimal.default(0),
  oc_iva: decimal.default(0),
  oc_total: decimal.default(0),
  estado_oc: estado3(["ABI", "APR", "ANU"]),
});

export const proxocCreate = z.object({
  id_compra: char(7),
  id_producto: char(7),
  pxo_cantidad: posInt,
  pxo_valor: decimal,
  pxo_subtotal: decimal,
  estado_pxoc: estado3(["ABI", "APR", "ANU"]),
});

export const recepcionCreate = z.object({
  id_recibo: char(7),
  id_compra: char(7),
  rec_descripcion: z.string().max(60).optional().nullable(),
  rec_num_productos: z.coerce.number().int().nonnegative().default(0),
  estado_rec: estado3(["PEN", "REC", "DEV"]),
});

// ═══════ MÓDULO 2 — INVENTARIOS ════════════════════════════════

export const bodegaCreate = z.object({
  id_bodega: char(3),
  bod_nombre: z.string().max(60),
  bod_descripcion: z.string().max(120).optional().nullable(),
  id_empleado: char(7),
  estado_bod: estado3(["ACT", "INA"]),
});

export const perchaCreate = z.object({
  id_percha: char(7),
  id_bodega: char(3),
  per_letra: z.string().length(1).regex(/[A-Z]/),
  per_numero: z.coerce.number().int().min(1),
  per_nivel: z.coerce.number().int().min(1),
  per_capacidad: decimal.default(0),
  estado_per: estado3(["ACT", "INA"]),
});

export const ajusteInvCreate = z.object({
  id_ajuste: char(7),
  id_bodega: char(3),
  id_empleado: char(7),
  aji_motivo: z.string().max(200),
  aji_observacion: z.string().max(300).optional().nullable(),
  estado_aji: estado3(["ABI", "APR", "ANU"]),
});

export const entregaCreate = z.object({
  id_entrega: char(7),
  id_bodega: char(3),
  id_empleado: char(7),
  ent_cli_ci: cedula,
  ent_cli_nombre: z.string().max(80),
  ent_referencia: z.string().max(10).optional().nullable(),
  estado_ent: estado3(["PEN", "ENT", "CAN"]),
});

// ═══════ MÓDULO 3 — VENTAS ═════════════════════════════════════

export const clienteCreate = z.object({
  id_cliente: char(7),
  cli_nombre: z.string().max(80),
  cli_ruc_ced: cedula,
  cli_telefono: z.string().max(10).optional().nullable(),
  cli_celular: z.string().max(10),
  cli_email: email,
  id_ciudad: char(3),
  cli_direccion: z.string().max(120),
  cli_tipo: z.enum(["JUR", "NAT"]),
  cli_descuento: z.coerce.number().min(0).max(100).default(0),
  cli_credito_max: decimal.default(0),
  estado_cli: estado3(["ACT", "INA"]),
});

export const vendedorCreate = z.object({
  id_vendedor: char(7),
  ven_comision: z.coerce.number().min(0).max(100).default(0),
  ven_meta_mes: decimal.default(0),
  estado_ven: estado3(["ACT", "INA"]),
});

export const facturaCreate = z.object({
  id_factura: char(7),
  fac_numero_sri: z.string().max(17),
  id_cliente: char(7),
  id_vendedor: char(7),
  id_forma_pago: char(3),
  id_entrega: charOpt(7).nullable(),
  id_asiento: charOpt(7).nullable(),
  fac_descripcion: z.string().max(200).optional().nullable(),
  fac_subtotal: decimal.default(0),
  fac_descuento: decimal.default(0),
  fac_iva: decimal.default(0),
  fac_ice: decimal.default(0),
  estado_fac: estado3(["ABI", "APR", "ANU"]),
});

export const facturaDetCreate = z.object({
  id_factura: char(7),
  fad_linea: posInt,
  id_producto: char(7),
  id_unidad_medida: char(3),
  fad_cantidad: z.coerce.number().positive(),
  fad_precio_unit: decimal,
  fad_descuento_ln: z.coerce.number().min(0).max(100).default(0),
  estado_fad: estado3(["ABI", "APR", "ANU"]),
});

export const devolucionCreate = z.object({
  id_devolucion: char(7),
  id_factura: char(7),
  id_empleado: char(7),
  dev_tipo: z.enum(["TOT", "PAR"]),
  dev_motivo: z.string().max(200),
  dev_subtotal: decimal.default(0),
  dev_iva: decimal.default(0),
  estado_dev: estado3(["PEN", "APR", "ANU"]),
});

// ═══════ MÓDULO 4 — CONTABILIDAD ═══════════════════════════════

export const cuentaCreate = z.object({
  id_cuenta: z.string().max(15),
  cue_descripcion: z.string().max(60),
  cue_tipo: char(3),
  estado_cue: estado3(["ACT", "INA"]),
});

export const asientoCreate = z.object({
  id_asiento: char(7),
  asi_descripcion: z.string().max(60),
  asi_total_debe: decimal.default(0),
  asi_total_haber: decimal.default(0),
  estado_asi: estado3(["PEN", "APR", "ANU"]),
});

// ═══════ MÓDULO 5 — TALENTO HUMANO ═════════════════════════════

export const empleadoCreate = z.object({
  id_empleado: char(7),
  emp_nombres: z.string().max(40),
  emp_apellidos: z.string().max(40),
  emp_cedula: z.string().length(10),
  id_departamento: char(3),
  id_rol: char(3),
  estado_emp: estado3(["ACT", "INA"]),
  // TTHH extension (all optional)
  emp_segundo_apellido: z.string().max(40).optional().nullable(),
  emp_segundo_nombre: z.string().max(40).optional().nullable(),
  emp_fecha_nacimiento: z.coerce.date().optional().nullable(),
  emp_sexo: z.enum(["M", "F"]).optional().nullable(),
  emp_email: email,
  emp_telefono: z.string().max(10).optional().nullable(),
  emp_celular: z.string().max(10).optional().nullable(),
  emp_direccion: z.string().max(120).optional().nullable(),
  emp_tipo_sangre: z.enum(["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"]).optional().nullable(),
  emp_sueldo: decimal.default(0),
  emp_fecha_ingreso: z.coerce.date().optional().nullable(),
  id_tipo_contrato: charOpt(3).nullable(),
  id_jefe: charOpt(7).nullable(),
});

export const rolPagosCreate = z.object({
  id_rol_pago: char(7),
  id_empleado: char(7),
  id_centro: charOpt(5).nullable(),
  rpl_anio: z.coerce.number().int(),
  rpl_mes: z.coerce.number().int().min(1).max(12),
  rpl_sueldo_base: decimal.default(0),
  rpl_total_ingresos: decimal.default(0),
  rpl_total_descuentos: decimal.default(0),
  estado_rpl: estado3(["ABI", "APR", "ANU"]),
});

export const asistenciaCreate = z.object({
  id_empleado: char(7),
  asi_fecha: z.coerce.date(),
  asi_tipo: z.enum(["PRE", "AUS", "TAR", "VAC"]).default("PRE"),
  asi_hora_entrada: z.string().optional().nullable(),
  asi_hora_salida: z.string().optional().nullable(),
  asi_justificada: z.boolean().default(false),
  asi_observacion: z.string().max(200).optional().nullable(),
});

// ═══════ AUTH ═══════════════════════════════════════════════════

export const loginSchema = z.object({
  emp_cedula: z.string().length(10),
  password: z.string().min(4),
});
