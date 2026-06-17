-- ████████████████████████████████████████████████████████████████████████
-- ██                                                                    ██
-- ██   COMERCIAL — SCRIPT DDL INTEGRADO  (PostgreSQL 16)               ██
-- ██   Sistema de Comercialización de Productos                         ██
-- ██   JW Cóndor | diciembre 2025                                       ██
-- ██                                                                    ██
-- ████████████████████████████████████████████████████████████████████████
--
--  COMPATIBILIDAD: PostgreSQL 16 (funciona desde PG 12 salvo GENERATED)
--
--  DIFERENCIAS CLAVE vs. versión MySQL/MariaDB:
--  ─────────────────────────────────────────────
--  ENGINE=InnoDB / ROW_FORMAT  → eliminados (nativo en PG)
--  AUTO_INCREMENT              → GENERATED ALWAYS AS IDENTITY
--  TINYINT(1)                  → BOOLEAN
--  TINYINT UNSIGNED            → SMALLINT
--  SMALLINT UNSIGNED           → INTEGER
--  INT / BIGINT UNSIGNED       → INTEGER / BIGINT
--  DATETIME                    → TIMESTAMP
--  LONGTEXT                    → TEXT
--  DECIMAL(p,s)                → NUMERIC(p,s)  [alias, ambos válidos en PG]
--  ENUM(...)                   → CREATE TYPE ... AS ENUM(...)
--  DELIMITER $$ ... DELIMITER  → $$ bloques (psql estándar)
--  SIGNAL SQLSTATE '45000'     → RAISE EXCEPTION
--  DATEDIFF(x, y)              → (x::DATE - y)  [retorna INTEGER]
--  CURDATE()                   → CURRENT_DATE
--  DATE(timestamp)             → timestamp::DATE
--  ON UPDATE CURRENT_TIMESTAMP → TRIGGER (fn_set_update_timestamp)
--  GENERATED con CURDATE()     → columna removida; ver VIEW v_cuotas_mora
--  COMMENT='...' (tabla)       → COMMENT ON TABLE ... IS '...'
--  INDEX ... COMMENT '...'     → ver COMERCIAL_INDEXES_PG16.sql
--  SHOW TABLES / DESCRIBE      → eliminados (diagnóstico)
--
--  INSTRUCCIONES DE EJECUCIÓN:
--  1. Como superusuario: CREATE DATABASE comercial ENCODING 'UTF8';
--  2. \c comercial
--  3. Ejecutar este archivo completo
--  4. Ejecutar COMERCIAL_INDEXES_PG16.sql
--
--  ORDEN DE BLOQUES (por dependencia de FK):
--    Bloque 0  — Schema y tipos ENUM
--    Bloque 1  — Catálogos geográficos
--    Bloque 2  — Catálogos de negocio
--    Bloque 3  — Módulo Compras
--    Bloque 4  — Módulo Contabilidad + Triggers partida doble
--    Bloque 5  — Infraestructura Auditoría
--    Bloque 6  — Módulo Inventarios + Trigger ON UPDATE timestamp
--    Bloque 7  — Módulo Ventas + Vista v_cuotas_mora
--    Bloque 8  — Módulo Talento Humano
--
--  TOTAL TABLAS : 50
--  TOTAL VISTAS : 1  (v_cuotas_mora — reemplaza columna GENERATED volátil)
--  TOTAL TRIGGERS: 3 (partida doble ×2 + timestamp ×1)
-- ████████████████████████████████████████████████████████████████████████


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 0 — SCHEMA Y TIPOS ENUM
-- ════════════════════════════════════════════════════════════════════════

DROP SCHEMA IF EXISTS comercial CASCADE;
CREATE SCHEMA comercial;
SET search_path TO comercial;

-- Tipo ENUM para operaciones de auditoría
CREATE TYPE tipo_operacion_dml AS ENUM ('INSERT', 'UPDATE', 'DELETE');

COMMENT ON SCHEMA comercial IS
    'Sistema de Comercialización de Productos — JW Cóndor 2025';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 1 — CATÁLOGOS GEOGRÁFICOS
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE provincias (
    id_provincia    CHAR(3)      NOT NULL,
    prv_descripcion VARCHAR(30)  NOT NULL,
    CONSTRAINT pk_provincias PRIMARY KEY (id_provincia)
);
COMMENT ON TABLE provincias IS 'Catálogo de provincias del Ecuador';


CREATE TABLE ciudades (
    id_ciudad       CHAR(3)     NOT NULL,
    ciu_descripcion VARCHAR(30) NOT NULL,
    id_provincia    CHAR(3)     NOT NULL,
    CONSTRAINT pk_ciudades PRIMARY KEY (id_ciudad),
    CONSTRAINT fk_ciu_prv  FOREIGN KEY (id_provincia)
        REFERENCES provincias(id_provincia)
        ON UPDATE CASCADE ON DELETE RESTRICT
);
COMMENT ON TABLE ciudades IS 'Catálogo de ciudades del Ecuador';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 2 — CATÁLOGOS DE NEGOCIO
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE unidades_medidas (
    id_unidad_medida CHAR(3)     NOT NULL,
    um_descripcion   VARCHAR(20) NOT NULL,
    CONSTRAINT pk_unidades_medidas PRIMARY KEY (id_unidad_medida)
);
COMMENT ON TABLE unidades_medidas IS 'Unidades de medida para compras y ventas';


CREATE TABLE departamentos (
    id_departamento CHAR(3)       NOT NULL,
    dep_descripcion VARCHAR(30)   NOT NULL,
    dep_presupuesto NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT pk_departamentos    PRIMARY KEY (id_departamento),
    CONSTRAINT chk_dep_presupuesto CHECK (dep_presupuesto >= 0)
);
COMMENT ON TABLE departamentos IS 'Departamentos internos de la empresa';


CREATE TABLE roles (
    id_rol          CHAR(3)     NOT NULL,
    rol_descripcion VARCHAR(30) NOT NULL,
    CONSTRAINT pk_roles PRIMARY KEY (id_rol)
);
COMMENT ON TABLE roles IS 'Roles del personal de todos los módulos';


CREATE TABLE categorias (
    id_categoria    CHAR(3)     NOT NULL,
    cat_descripcion VARCHAR(30) NOT NULL,
    CONSTRAINT pk_categorias PRIMARY KEY (id_categoria)
);
COMMENT ON TABLE categorias IS 'Categorías de productos';


CREATE TABLE th_descuentos (
    id_descuento    CHAR(3)      NOT NULL,
    des_descripcion VARCHAR(30)  NOT NULL,
    des_valor       NUMERIC(7,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT pk_th_descuentos PRIMARY KEY (id_descuento),
    CONSTRAINT chk_des_valor    CHECK (des_valor BETWEEN 0 AND 100)
);
COMMENT ON TABLE th_descuentos IS 'Tabla maestra de descuentos para órdenes de compra';


CREATE TABLE th_bonificaciones (
    id_bonificacion CHAR(3)      NOT NULL,
    bon_descripcion VARCHAR(30)  NOT NULL,
    bon_valor       NUMERIC(7,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT pk_th_bonificaciones PRIMARY KEY (id_bonificacion),
    CONSTRAINT chk_bon_valor        CHECK (bon_valor >= 0)
);
COMMENT ON TABLE th_bonificaciones IS 'Tabla maestra de bonificaciones de proveedores';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 3 — MÓDULO COMPRAS
-- ════════════════════════════════════════════════════════════════════════

-- --------------------------------------------------------------------
--  3.1  PRODUCTOS
--       pro_saldo_final: columna GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE productos (
    id_producto       CHAR(7)       NOT NULL,
    id_categoria      CHAR(3)       NOT NULL,
    pro_nombre        VARCHAR(40)   NOT NULL,
    pro_descripcion   VARCHAR(100),
    fk_pro_um_compra  CHAR(3)       NOT NULL,
    fk_pro_um_venta   CHAR(3)       NOT NULL,
    pro_valor_compra  NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    pro_precio_venta  NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    pro_saldo_inicial INTEGER       NOT NULL DEFAULT 0,
    pro_qty_ingresos  INTEGER       NOT NULL DEFAULT 0,
    pro_qty_egresos   INTEGER       NOT NULL DEFAULT 0,
    pro_qty_ajustes   INTEGER       NOT NULL DEFAULT 0,
    pro_saldo_final   INTEGER GENERATED ALWAYS AS (
        pro_saldo_inicial
        + pro_qty_ingresos
        - pro_qty_egresos
        + pro_qty_ajustes
    ) STORED,
    estado_prod       CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_productos         PRIMARY KEY (id_producto),
    CONSTRAINT uq_pro_nombre        UNIQUE      (pro_nombre),
    CONSTRAINT fk_pro_categoria     FOREIGN KEY (id_categoria)
        REFERENCES categorias(id_categoria)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pro_um_compra     FOREIGN KEY (fk_pro_um_compra)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pro_um_venta      FOREIGN KEY (fk_pro_um_venta)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_pro_valor_compra CHECK (pro_valor_compra  >= 0),
    CONSTRAINT chk_pro_precio_venta CHECK (pro_precio_venta  >= 0),
    CONSTRAINT chk_pro_saldo_ini    CHECK (pro_saldo_inicial >= 0),
    CONSTRAINT chk_estado_prod      CHECK (estado_prod IN ('ACT','INA'))
);
COMMENT ON TABLE productos IS 'Catálogo de productos comercializados';
COMMENT ON COLUMN productos.pro_saldo_final
    IS 'GENERATED STORED: saldo_inicial + ingresos - egresos + ajustes';


-- --------------------------------------------------------------------
--  3.2  EMPLEADOS — base operativa (extendida en Bloque 8 via ALTER)
--       emp_cedula VARCHAR(10) + CHECK en vez de CHAR(10) para que
--       LENGTH() valide el contenido real sin padding de espacios.
-- --------------------------------------------------------------------
CREATE TABLE empleados (
    id_empleado     CHAR(7)     NOT NULL,
    emp_nombres     VARCHAR(40) NOT NULL,
    emp_apellidos   VARCHAR(40) NOT NULL,
    emp_cedula      VARCHAR(10) NOT NULL,
    id_departamento CHAR(3)     NOT NULL,
    id_rol          CHAR(3)     NOT NULL,
    estado_emp      CHAR(3)     NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_empleados   PRIMARY KEY (id_empleado),
    CONSTRAINT uq_emp_cedula  UNIQUE      (emp_cedula),
    CONSTRAINT fk_emp_dpto    FOREIGN KEY (id_departamento)
        REFERENCES departamentos(id_departamento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_emp_rol     FOREIGN KEY (id_rol)
        REFERENCES roles(id_rol)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_emp_cedula CHECK (LENGTH(emp_cedula) = 10),
    CONSTRAINT chk_estado_emp CHECK (estado_emp IN ('ACT','INA'))
);
COMMENT ON TABLE empleados IS
    'Empleados — base operativa. Módulo TTHH extiende vía ALTER TABLE.';


-- --------------------------------------------------------------------
--  3.3  PROVEEDORES
--       prv_ruc_ced VARCHAR(13) para CHECK de longitud real.
-- --------------------------------------------------------------------
CREATE TABLE proveedores (
    id_proveedor  CHAR(7)      NOT NULL,
    prv_nombre    VARCHAR(40)  NOT NULL,
    prv_ruc_ced   VARCHAR(13)  NOT NULL,
    prv_telefono  VARCHAR(10),
    prv_celular   VARCHAR(10),
    prv_mail      VARCHAR(60),
    id_ciudad     CHAR(3)      NOT NULL,
    prv_direccion VARCHAR(60),
    prv_tipo      CHAR(3)      NOT NULL,
    estado_prv    CHAR(3)      NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_proveedores  PRIMARY KEY (id_proveedor),
    CONSTRAINT uq_prv_ruc_ced  UNIQUE      (prv_ruc_ced),
    CONSTRAINT fk_prv_ciudad   FOREIGN KEY (id_ciudad)
        REFERENCES ciudades(id_ciudad)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_prv_tipo    CHECK (prv_tipo   IN ('JUR','NAT')),
    CONSTRAINT chk_estado_prv  CHECK (estado_prv IN ('ACT','INA')),
    CONSTRAINT chk_prv_mail    CHECK (prv_mail LIKE '%@%.%' OR prv_mail IS NULL)
);
COMMENT ON TABLE proveedores IS 'Proveedores activos e históricos';


-- --------------------------------------------------------------------
--  3.4  PROVEEDOR_PRODUCTO — catálogo N:M
-- --------------------------------------------------------------------
CREATE TABLE proveedor_producto (
    id_proveedor CHAR(7) NOT NULL,
    id_producto  CHAR(7) NOT NULL,
    CONSTRAINT pk_proveedor_producto PRIMARY KEY (id_proveedor, id_producto),
    CONSTRAINT fk_pp_proveedor       FOREIGN KEY (id_proveedor)
        REFERENCES proveedores(id_proveedor)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_pp_producto        FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE CASCADE
);
COMMENT ON TABLE proveedor_producto
    IS 'Relación N:M entre proveedores y productos que comercializan';


-- --------------------------------------------------------------------
--  3.5  COMPRAS — cabecera de Orden de Compra
--       En PG, DATE(oc_fecha) → oc_fecha::DATE
-- --------------------------------------------------------------------
CREATE TABLE compras (
    id_compra        CHAR(7)       NOT NULL,
    id_proveedor     CHAR(7)       NOT NULL,
    id_descuento     CHAR(3),
    id_empleado      CHAR(7)       NOT NULL,
    id_departamento  CHAR(3)       NOT NULL,
    oc_fecha         TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    oc_fecha_entrega DATE          NOT NULL,
    oc_subtotal      NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    oc_iva           NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    oc_total         NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    estado_oc        CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_compras       PRIMARY KEY (id_compra),
    CONSTRAINT fk_oc_proveedor  FOREIGN KEY (id_proveedor)
        REFERENCES proveedores(id_proveedor)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_oc_descuento  FOREIGN KEY (id_descuento)
        REFERENCES th_descuentos(id_descuento)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_oc_empleado   FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_oc_dpto       FOREIGN KEY (id_departamento)
        REFERENCES departamentos(id_departamento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_oc    CHECK (estado_oc  IN ('ABI','APR','ANU')),
    CONSTRAINT chk_oc_subtotal  CHECK (oc_subtotal >= 0),
    CONSTRAINT chk_oc_iva       CHECK (oc_iva      >= 0),
    CONSTRAINT chk_oc_total     CHECK (oc_total    >= 0),
    CONSTRAINT chk_oc_fechas    CHECK (oc_fecha::DATE <= oc_fecha_entrega)
);
COMMENT ON TABLE compras IS 'Cabecera de Órdenes de Compra (ABI|APR|ANU)';


-- --------------------------------------------------------------------
--  3.6  PROXOC — detalle de Orden de Compra
-- --------------------------------------------------------------------
CREATE TABLE proxoc (
    id_compra    CHAR(7)       NOT NULL,
    id_producto  CHAR(7)       NOT NULL,
    pxo_cantidad INTEGER       NOT NULL DEFAULT 1,
    pxo_valor    NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    pxo_subtotal NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    estado_pxoc  CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_proxoc         PRIMARY KEY (id_compra, id_producto),
    CONSTRAINT fk_pxoc_compra    FOREIGN KEY (id_compra)
        REFERENCES compras(id_compra)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_pxoc_producto  FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_pxoc   CHECK (estado_pxoc  IN ('ABI','APR','ANU')),
    CONSTRAINT chk_pxoc_cantidad CHECK (pxo_cantidad > 0),
    CONSTRAINT chk_pxoc_valor    CHECK (pxo_valor    >= 0),
    CONSTRAINT chk_pxoc_subtotal CHECK (pxo_subtotal >= 0)
);
COMMENT ON TABLE proxoc IS 'Detalle de productos por Orden de Compra';


-- --------------------------------------------------------------------
--  3.7  RECEPCIONES — Orden de Ingreso a Bodega
-- --------------------------------------------------------------------
CREATE TABLE recepciones (
    id_recibo         CHAR(7)    NOT NULL,
    id_compra         CHAR(7)    NOT NULL,
    rec_descripcion   VARCHAR(60),
    rec_fecha_hora    TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    rec_num_productos INTEGER    NOT NULL DEFAULT 0,
    estado_rec        CHAR(3)    NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_recepciones    PRIMARY KEY (id_recibo),
    CONSTRAINT fk_rec_compra     FOREIGN KEY (id_compra)
        REFERENCES compras(id_compra)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_rec    CHECK (estado_rec       IN ('PEN','REC','DEV')),
    CONSTRAINT chk_rec_num_prod  CHECK (rec_num_productos >= 0)
);
COMMENT ON TABLE recepciones IS 'Órdenes de Ingreso a Bodega (recepciones de compra)';


-- --------------------------------------------------------------------
--  3.8  PROXREC — detalle de Recepción
-- --------------------------------------------------------------------
CREATE TABLE proxrec (
    id_recibo        CHAR(7)  NOT NULL,
    id_producto      CHAR(7)  NOT NULL,
    prx_cantidad     INTEGER  NOT NULL DEFAULT 0,
    prx_qty_recibida INTEGER  NOT NULL DEFAULT 0,
    estado_pxrec     CHAR(3)  NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_proxrec            PRIMARY KEY (id_recibo, id_producto),
    CONSTRAINT fk_pxrec_recibo       FOREIGN KEY (id_recibo)
        REFERENCES recepciones(id_recibo)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_pxrec_producto     FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_pxrec      CHECK (estado_pxrec     IN ('PEN','REC','DEV')),
    CONSTRAINT chk_prx_cantidad      CHECK (prx_cantidad     >= 0),
    CONSTRAINT chk_prx_qty_recibida  CHECK (prx_qty_recibida >= 0)
);
COMMENT ON TABLE proxrec IS 'Detalle de productos recibidos por recepción de bodega';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 4 — MÓDULO CONTABILIDAD
--  Posicionado antes de Inventarios y Ventas porque ambos
--  referencian la tabla `asientos` via FK.
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE tipo_cuenta (
    id_tipo_cta     CHAR(3)     NOT NULL,
    tip_descripcion VARCHAR(30) NOT NULL,
    CONSTRAINT pk_tipo_cuenta PRIMARY KEY (id_tipo_cta)
);
COMMENT ON TABLE tipo_cuenta IS 'Tipos de cuenta contable (activo, pasivo, patrimonio, etc.)';


CREATE TABLE cuentas (
    id_cuenta       CHAR(15)      NOT NULL,
    cue_descripcion VARCHAR(60)   NOT NULL,
    cue_tipo        CHAR(3)       NOT NULL,
    cue_debe00      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe01      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe02      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe03      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe04      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe11      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe12      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_debe13      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber00     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber01     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber02     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber03     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber10     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber11     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber12     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cue_haber13     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    user_id         CHAR(16),
    estado_cue      CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_cuentas         PRIMARY KEY (id_cuenta),
    CONSTRAINT uq_cue_descripcion UNIQUE      (cue_descripcion),
    CONSTRAINT fk_cue_tipo        FOREIGN KEY (cue_tipo)
        REFERENCES tipo_cuenta(id_tipo_cta)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_cue     CHECK (estado_cue IN ('ACT','INA'))
);
COMMENT ON TABLE cuentas IS
    'Plan de cuentas contable jerárquico (niveles 1-5). Se conservan INACTIVAS.';
COMMENT ON COLUMN cuentas.id_cuenta
    IS 'CHAR(15): soporta plan jerárquico separado por puntos, ej. 1.1.01.01.01';


CREATE TABLE asientos (
    id_asiento      CHAR(7)       NOT NULL,
    asi_descripcion VARCHAR(60)   NOT NULL,
    asi_total_debe  NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    asi_total_haber NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    asi_fecha_hora  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    user_id         CHAR(16),
    estado_asi      CHAR(3)       NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_asientos    PRIMARY KEY (id_asiento),
    CONSTRAINT chk_estado_asi CHECK (estado_asi     IN ('PEN','APR','ANU')),
    CONSTRAINT chk_asi_debe   CHECK (asi_total_debe  >= 0),
    CONSTRAINT chk_asi_haber  CHECK (asi_total_haber >= 0)
);
COMMENT ON TABLE asientos IS
    'Asientos contables generados por todos los módulos (PEN/APR/ANU/ERR)';


CREATE TABLE ctaxasi (
    id_asiento  CHAR(7)       NOT NULL,
    id_cuenta   CHAR(15)      NOT NULL,
    cxa_debe    NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    cxa_haber   NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    estado_cxa  CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_ctaxasi      PRIMARY KEY (id_asiento, id_cuenta),
    CONSTRAINT fk_cxa_asiento  FOREIGN KEY (id_asiento)
        REFERENCES asientos(id_asiento)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_cxa_cuenta   FOREIGN KEY (id_cuenta)
        REFERENCES cuentas(id_cuenta)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_cxa  CHECK (estado_cxa IN ('ACT','INA')),
    CONSTRAINT chk_cxa_debe    CHECK (cxa_debe   >= 0),
    CONSTRAINT chk_cxa_haber   CHECK (cxa_haber  >= 0),
    CONSTRAINT chk_cxa_no_cero CHECK (cxa_debe > 0 OR cxa_haber > 0)
);
COMMENT ON TABLE ctaxasi IS 'Partidas de cuentas dentro de un asiento contable';


-- --------------------------------------------------------------------
--  4.5  FUNCIÓN + TRIGGERS — Validación Partida Doble
--       En PG los triggers necesitan una función separada que retorne TRIGGER.
--       RAISE EXCEPTION reemplaza SIGNAL SQLSTATE '45000'.
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validar_partida_doble()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.asi_total_debe <> NEW.asi_total_haber THEN
        RAISE EXCEPTION
            'ERROR Partida Doble: DEBE (%) ≠ HABER (%) en el asiento %',
            NEW.asi_total_debe, NEW.asi_total_haber, NEW.id_asiento;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_validar_partida_doble()
    IS 'Valida que DEBE = HABER antes de INSERT/UPDATE en asientos';

CREATE TRIGGER trg_asi_partida_doble_ins
BEFORE INSERT ON asientos
FOR EACH ROW EXECUTE FUNCTION fn_validar_partida_doble();

CREATE TRIGGER trg_asi_partida_doble_upd
BEFORE UPDATE ON asientos
FOR EACH ROW EXECUTE FUNCTION fn_validar_partida_doble();


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 5 — INFRAESTRUCTURA DE AUDITORÍA
--  Tabla transversal; recibe logs DML de triggers de todos los módulos.
--  id_auditoria: INTEGER GENERATED ALWAYS AS IDENTITY (reemplaza AUTO_INCREMENT)
--  operacion: usa el TYPE ENUM definido en Bloque 0.
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE auditoria_sistema (
    id_auditoria   INTEGER           NOT NULL GENERATED ALWAYS AS IDENTITY,
    usuario_db     VARCHAR(80)       NOT NULL,
    tabla_afectada VARCHAR(30)       NOT NULL,
    operacion      tipo_operacion_dml NOT NULL,
    id_registro    VARCHAR(35)       NOT NULL,
    valor_anterior TEXT,
    valor_nuevo    TEXT,
    fecha_hora     TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ip_terminal    VARCHAR(45),
    CONSTRAINT pk_auditoria PRIMARY KEY (id_auditoria)
);
COMMENT ON TABLE auditoria_sistema
    IS 'Registro centralizado de todas las operaciones DML del sistema';
COMMENT ON COLUMN auditoria_sistema.id_registro
    IS 'PK del registro afectado (puede ser PK compuesta serializada como JSON)';
COMMENT ON COLUMN auditoria_sistema.operacion
    IS 'Tipo ENUM: INSERT | UPDATE | DELETE';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 6 — MÓDULO INVENTARIOS
--  Depende de: empleados, productos, unidades_medidas, asientos.
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE bodegas (
    id_bodega       CHAR(3)     NOT NULL,
    bod_nombre      VARCHAR(60) NOT NULL,
    bod_descripcion VARCHAR(120),
    id_empleado     CHAR(7)     NOT NULL,
    estado_bod      CHAR(3)     NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_bodegas      PRIMARY KEY (id_bodega),
    CONSTRAINT uq_bod_nombre   UNIQUE      (bod_nombre),
    CONSTRAINT fk_bod_empleado FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_bod  CHECK (estado_bod IN ('ACT','INA'))
);
COMMENT ON TABLE bodegas IS 'Almacenes físicos de la empresa';
COMMENT ON COLUMN bodegas.id_empleado IS 'Jefe de bodega responsable';


-- --------------------------------------------------------------------
--  6.2  PERCHAS
--       per_numero / per_nivel: SMALLINT (reemplaza TINYINT UNSIGNED)
-- --------------------------------------------------------------------
CREATE TABLE perchas (
    id_percha    CHAR(7)  NOT NULL,
    id_bodega    CHAR(3)  NOT NULL,
    per_letra    CHAR(1)  NOT NULL,
    per_numero   SMALLINT NOT NULL,
    per_nivel    SMALLINT NOT NULL,
    per_capacidad  NUMERIC(12,4) NOT NULL DEFAULT 0,
    estado_per   CHAR(3)  NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_perchas        PRIMARY KEY (id_percha),
    CONSTRAINT uq_per_ubicacion  UNIQUE      (id_bodega, per_letra, per_numero, per_nivel),
    CONSTRAINT fk_per_bodega     FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_per_letra     CHECK (per_letra   BETWEEN 'A' AND 'Z'),
    CONSTRAINT chk_per_numero    CHECK (per_numero  >= 1),
    CONSTRAINT chk_per_nivel     CHECK (per_nivel   >= 1),
    CONSTRAINT chk_per_capacidad CHECK (per_capacidad >= 0),
    CONSTRAINT chk_estado_per    CHECK (estado_per IN ('ACT','INA'))
);
COMMENT ON TABLE perchas IS 'Perchas y niveles de almacenamiento dentro de cada bodega';
COMMENT ON COLUMN perchas.per_letra
    IS 'Fila del estante (A-Z)';
COMMENT ON COLUMN perchas.per_numero
    IS 'Número de estante (1-99)';
COMMENT ON COLUMN perchas.per_nivel
    IS 'Nivel/altura (1-9)';


CREATE TABLE factor_conversion (
    id_producto     CHAR(7)       NOT NULL,
    fac_factor      NUMERIC(14,6) NOT NULL DEFAULT 1.000000,
    fac_descripcion VARCHAR(80),
    CONSTRAINT pk_factor_conversion PRIMARY KEY (id_producto),
    CONSTRAINT fk_fac_producto      FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT chk_fac_factor       CHECK (fac_factor > 0)
);
COMMENT ON TABLE factor_conversion
    IS 'Factor de conversión UM-compra ↔ UM-venta por producto (req #1)';
COMMENT ON COLUMN factor_conversion.fac_factor
    IS 'Unidades de venta equivalentes a 1 unidad de compra. Ej: 1 caja = 12 uds → 12';


CREATE TABLE ubicacion_percha (
    id_producto  CHAR(7)       NOT NULL,
    id_percha    CHAR(7)       NOT NULL,
    ubp_cantidad NUMERIC(12,4) NOT NULL DEFAULT 0,
    CONSTRAINT pk_ubicacion_percha PRIMARY KEY (id_producto, id_percha),
    CONSTRAINT fk_ubp_producto     FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ubp_percha       FOREIGN KEY (id_percha)
        REFERENCES perchas(id_percha)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_ubp_cantidad    CHECK (ubp_cantidad >= 0)
);
COMMENT ON TABLE ubicacion_percha
    IS 'Localización y cantidad de producto por percha (req #2 #5 #7)';


-- --------------------------------------------------------------------
--  6.5  STOCK_BODEGA — saldo materializado
--       stk_disponible: GENERATED STORED (determinista — OK en PG).
--       stk_ultima_act: actualizado por TRIGGER (no existe ON UPDATE en PG).
-- --------------------------------------------------------------------
CREATE TABLE stock_bodega (
    id_producto    CHAR(7)       NOT NULL,
    id_bodega      CHAR(3)       NOT NULL,
    stk_cantidad   NUMERIC(12,4) NOT NULL DEFAULT 0,
    stk_reservado  NUMERIC(12,4) NOT NULL DEFAULT 0,
    stk_disponible NUMERIC(12,4) GENERATED ALWAYS AS
        (stk_cantidad - stk_reservado) STORED,
    stk_costo_prom NUMERIC(14,6) NOT NULL DEFAULT 0,
    stk_ultima_act TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_stock_bodega    PRIMARY KEY (id_producto, id_bodega),
    CONSTRAINT fk_stk_producto    FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_stk_bodega      FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_stk_cantidad   CHECK (stk_cantidad   >= 0),
    CONSTRAINT chk_stk_reservado  CHECK (stk_reservado  >= 0),
    CONSTRAINT chk_stk_costo_prom CHECK (stk_costo_prom >= 0)
);
COMMENT ON TABLE stock_bodega IS 'Stock materializado por producto/bodega — método CPP';
COMMENT ON COLUMN stock_bodega.stk_disponible
    IS 'GENERATED STORED: stk_cantidad - stk_reservado';
COMMENT ON COLUMN stock_bodega.stk_ultima_act
    IS 'Actualizado automáticamente por trg_stk_update_timestamp en cada UPDATE';

-- Trigger para simular ON UPDATE CURRENT_TIMESTAMP de MySQL en stk_ultima_act
CREATE OR REPLACE FUNCTION fn_set_update_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.stk_ultima_act := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_set_update_timestamp()
    IS 'Actualiza stk_ultima_act al momento exacto de cada UPDATE en stock_bodega';

CREATE TRIGGER trg_stk_update_timestamp
BEFORE UPDATE ON stock_bodega
FOR EACH ROW EXECUTE FUNCTION fn_set_update_timestamp();


-- --------------------------------------------------------------------
--  6.6  AJUSTES_INV — cabecera de Ajuste de Inventario
--       aji_num_prod: INTEGER (reemplaza SMALLINT UNSIGNED)
-- --------------------------------------------------------------------
CREATE TABLE ajustes_inv (
    id_ajuste       CHAR(7)   NOT NULL,
    id_bodega       CHAR(3)   NOT NULL,
    id_empleado     CHAR(7)   NOT NULL,
    id_aprobador    CHAR(7),
    id_asiento      CHAR(7),
    aji_motivo      VARCHAR(200)  NOT NULL,
    aji_fecha       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    aji_fecha_apr   TIMESTAMP,
    aji_num_prod    INTEGER       NOT NULL DEFAULT 0,
    aji_total       NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    aji_observacion VARCHAR(300),
    estado_aji      CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_ajustes_inv    PRIMARY KEY (id_ajuste),
    CONSTRAINT fk_aji_bodega     FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_aji_empleado   FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_aji_aprobador  FOREIGN KEY (id_aprobador)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_aji_asiento    FOREIGN KEY (id_asiento)
        REFERENCES asientos(id_asiento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_aji    CHECK (estado_aji  IN ('ABI','APR','ANU')),
    CONSTRAINT chk_aji_num_prod  CHECK (aji_num_prod >= 0),
    CONSTRAINT chk_aji_total     CHECK (aji_total    >= 0)
);
COMMENT ON TABLE ajustes_inv IS 'Cabecera de Ajuste de Inventario (ABI|APR|ANU)';
COMMENT ON COLUMN ajustes_inv.id_aprobador
    IS 'Jefe de bodega o contralor que aprueba. NULL hasta la aprobación.';
COMMENT ON COLUMN ajustes_inv.id_asiento
    IS 'Asiento contable generado al aprobar. NULL hasta APR.';


-- --------------------------------------------------------------------
--  6.7  AJUSTE_INV_DET — detalle del Ajuste
--       ajd_linea: INTEGER (reemplaza SMALLINT UNSIGNED)
--       ajd_subtotal: GENERATED STORED — ABS() es determinista en PG.
-- --------------------------------------------------------------------
CREATE TABLE ajuste_inv_det (
    id_ajuste        CHAR(7)       NOT NULL,
    ajd_linea        INTEGER       NOT NULL,
    id_producto      CHAR(7)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    ajd_cantidad     NUMERIC(12,4) NOT NULL,
    ajd_costo_unit   NUMERIC(14,4) NOT NULL DEFAULT 0,
    ajd_subtotal     NUMERIC(14,2) GENERATED ALWAYS AS
        (ABS(ajd_cantidad) * ajd_costo_unit) STORED,
    ajd_qty_ant      NUMERIC(12,4) NOT NULL DEFAULT 0,
    ajd_qty_nva      NUMERIC(12,4) NOT NULL DEFAULT 0,
    estado_ajd       CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_ajuste_inv_det  PRIMARY KEY (id_ajuste, ajd_linea),
    CONSTRAINT fk_ajd_ajuste      FOREIGN KEY (id_ajuste)
        REFERENCES ajustes_inv(id_ajuste)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ajd_producto    FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ajd_um          FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_ajd     CHECK (estado_ajd     IN ('ABI','APR','ANU')),
    CONSTRAINT chk_ajd_costo_unit CHECK (ajd_costo_unit >= 0)
);
COMMENT ON TABLE ajuste_inv_det IS 'Detalle de productos en un Ajuste de Inventario';
COMMENT ON COLUMN ajuste_inv_det.ajd_cantidad
    IS 'Positivo = incremento; Negativo = disminución de stock';
COMMENT ON COLUMN ajuste_inv_det.ajd_subtotal
    IS 'GENERATED STORED: ABS(ajd_cantidad) * ajd_costo_unit';


-- --------------------------------------------------------------------
--  6.8  ENTREGAS — cabecera de Entrega de Productos al cliente
--       ent_cli_ci VARCHAR(13) para CHECK de longitud real.
-- --------------------------------------------------------------------
CREATE TABLE entregas (
    id_entrega      CHAR(7)      NOT NULL,
    id_bodega       CHAR(3)      NOT NULL,
    id_empleado     CHAR(7)      NOT NULL,
    ent_cli_ci      VARCHAR(13)  NOT NULL,
    ent_cli_nombre  VARCHAR(80)  NOT NULL,
    ent_referencia  VARCHAR(10),
    ent_fecha       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ent_num_prod    INTEGER      NOT NULL DEFAULT 0,
    ent_obs_can     VARCHAR(200),
    estado_ent      CHAR(3)      NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_entregas      PRIMARY KEY (id_entrega),
    CONSTRAINT fk_ent_bodega    FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ent_empleado  FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_ent   CHECK (estado_ent   IN ('PEN','ENT','CAN')),
    CONSTRAINT chk_ent_num_prod CHECK (ent_num_prod >= 0),
    CONSTRAINT chk_ent_cli_ci   CHECK (LENGTH(TRIM(ent_cli_ci)) IN (10,13))
);
COMMENT ON TABLE entregas
    IS 'Cabecera de Entrega de Productos al cliente (PEN|ENT|CAN)';
COMMENT ON COLUMN entregas.ent_cli_ci
    IS 'Cédula (10 dígitos) o RUC (13 dígitos) del cliente receptor';
COMMENT ON COLUMN entregas.ent_referencia
    IS 'Número de factura origen (referencia al módulo ventas)';


-- --------------------------------------------------------------------
--  6.9  ENTREGA_DET — líneas de la Entrega
--       etd_diferencia: GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE entrega_det (
    id_entrega       CHAR(7)       NOT NULL,
    etd_linea        INTEGER       NOT NULL,
    id_producto      CHAR(7)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    etd_qty_sol      NUMERIC(12,4) NOT NULL,
    etd_qty_ent      NUMERIC(12,4) NOT NULL DEFAULT 0,
    etd_diferencia   NUMERIC(12,4) GENERATED ALWAYS AS
        (etd_qty_sol - etd_qty_ent) STORED,
    etd_motivo_dif   VARCHAR(200),
    estado_etd       CHAR(3)       NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_entrega_det   PRIMARY KEY (id_entrega, etd_linea),
    CONSTRAINT fk_etd_entrega   FOREIGN KEY (id_entrega)
        REFERENCES entregas(id_entrega)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_etd_producto  FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_etd_um        FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_etd   CHECK (estado_etd  IN ('PEN','ENT','CAN')),
    CONSTRAINT chk_etd_qty_sol  CHECK (etd_qty_sol  > 0),
    CONSTRAINT chk_etd_qty_ent  CHECK (etd_qty_ent >= 0)
);
COMMENT ON TABLE entrega_det IS 'Detalle de líneas en una Entrega de Productos (req #3 #9)';
COMMENT ON COLUMN entrega_det.etd_diferencia
    IS 'GENERATED STORED: etd_qty_sol - etd_qty_ent. ≠ 0 = entrega incompleta (req #9)';


-- --------------------------------------------------------------------
--  6.10 MOVIMIENTOS_INV — ledger append-only
--       id_movimiento: BIGINT GENERATED ALWAYS AS IDENTITY.
--       mvi_origen: VARCHAR(7) + CHECK en vez de ENUM
--         (COMPRA=6, AJUSTE=6, DEVOLU=6, ENTREGA=7 → max 7).
-- --------------------------------------------------------------------
CREATE TABLE movimientos_inv (
    id_movimiento    BIGINT        NOT NULL GENERATED ALWAYS AS IDENTITY,
    id_producto      CHAR(7)       NOT NULL,
    id_bodega        CHAR(3)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    mvi_tipo         CHAR(3)       NOT NULL,
    mvi_origen       VARCHAR(7)    NOT NULL,
    id_referencia    VARCHAR(10)   NOT NULL,
    mvi_fecha        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    mvi_cantidad     NUMERIC(12,4) NOT NULL,
    mvi_costo_unit   NUMERIC(14,4) NOT NULL DEFAULT 0,
    mvi_stk_ant      NUMERIC(12,4) NOT NULL DEFAULT 0,
    mvi_stk_pos      NUMERIC(12,4) NOT NULL DEFAULT 0,
    id_empleado      CHAR(7)       NOT NULL,
    CONSTRAINT pk_movimientos_inv PRIMARY KEY (id_movimiento),
    CONSTRAINT fk_mvi_producto    FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_mvi_bodega      FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_mvi_um          FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_mvi_empleado    FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_mvi_tipo       CHECK (mvi_tipo   IN ('ING','EGR','AJU','TRF')),
    CONSTRAINT chk_mvi_origen     CHECK (mvi_origen IN ('COMPRA','ENTREGA','AJUSTE','DEVOLU')),
    CONSTRAINT chk_mvi_costo_unit CHECK (mvi_costo_unit >= 0)
);
COMMENT ON TABLE movimientos_inv
    IS 'Ledger de movimientos de inventario — append-only (req #8 #11 #12)';
COMMENT ON COLUMN movimientos_inv.id_movimiento
    IS 'BIGINT GENERATED ALWAYS AS IDENTITY — millones de filas sin reciclar IDs';
COMMENT ON COLUMN movimientos_inv.mvi_cantidad
    IS 'Positivo = ingreso/incremento; Negativo = egreso/disminución';


CREATE TABLE inventario_fisico (
    id_inv_fisico   CHAR(7)      NOT NULL,
    id_bodega       CHAR(3)      NOT NULL,
    id_empleado     CHAR(7)      NOT NULL,
    ivf_fecha       DATE         NOT NULL,
    ivf_observacion VARCHAR(300),
    estado_ivf      CHAR(3)      NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_inventario_fisico  PRIMARY KEY (id_inv_fisico),
    CONSTRAINT fk_ivf_bodega         FOREIGN KEY (id_bodega)
        REFERENCES bodegas(id_bodega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ivf_empleado       FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_ivf        CHECK (estado_ivf IN ('ABI','CER'))
);
COMMENT ON TABLE inventario_fisico
    IS 'Cabecera de Constatación Física de Inventario (ABI|CER)';
COMMENT ON COLUMN inventario_fisico.id_empleado
    IS 'Quien ordena la constatación — NO quien la ejecuta físicamente';


-- --------------------------------------------------------------------
--  6.12 INVENTARIO_FISICO_DET
--       ivd_linea, etd_linea: INTEGER (reemplaza SMALLINT UNSIGNED).
--       ivd_diferencia: GENERATED — COALESCE es determinista en PG.
-- --------------------------------------------------------------------
CREATE TABLE inventario_fisico_det (
    id_inv_fisico    CHAR(7)       NOT NULL,
    ivd_linea        INTEGER       NOT NULL,
    id_producto      CHAR(7)       NOT NULL,
    id_percha        CHAR(7)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    ivd_qty_sis      NUMERIC(12,4) NOT NULL,
    ivd_qty_fis      NUMERIC(12,4),
    ivd_diferencia   NUMERIC(12,4) GENERATED ALWAYS AS
        (COALESCE(ivd_qty_fis, 0) - ivd_qty_sis) STORED,
    id_verificador   CHAR(7),
    CONSTRAINT pk_inventario_fisico_det PRIMARY KEY (id_inv_fisico, ivd_linea),
    CONSTRAINT fk_ivd_inv               FOREIGN KEY (id_inv_fisico)
        REFERENCES inventario_fisico(id_inv_fisico)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ivd_producto          FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ivd_percha            FOREIGN KEY (id_percha)
        REFERENCES perchas(id_percha)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ivd_um                FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ivd_verificador       FOREIGN KEY (id_verificador)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_ivd_qty_sis          CHECK (ivd_qty_sis >= 0),
    CONSTRAINT chk_ivd_qty_fis          CHECK (ivd_qty_fis IS NULL OR ivd_qty_fis >= 0)
);
COMMENT ON TABLE inventario_fisico_det
    IS 'Detalle de Constatación Física por producto y percha (req #5 #7)';
COMMENT ON COLUMN inventario_fisico_det.ivd_qty_fis
    IS 'NULL hasta que el verificador registre — permite imprimir formulario en blanco';
COMMENT ON COLUMN inventario_fisico_det.ivd_diferencia
    IS 'GENERATED STORED: COALESCE(qty_fis,0) - qty_sis. +sobrante / -faltante';
COMMENT ON COLUMN inventario_fisico_det.id_verificador
    IS 'Req #5: persona DISTINTA al bodeguero que realiza el conteo físico';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 7 — MÓDULO VENTAS
--  Depende de: ciudades, empleados, productos, unidades_medidas,
--              asientos, entregas.
-- ════════════════════════════════════════════════════════════════════════

-- --------------------------------------------------------------------
--  7.1  CLIENTES
--       cli_ruc_ced VARCHAR(13) para CHECK de longitud real.
-- --------------------------------------------------------------------
CREATE TABLE clientes (
    id_cliente      CHAR(7)       NOT NULL,
    cli_nombre      VARCHAR(80)   NOT NULL,
    cli_ruc_ced     VARCHAR(13)   NOT NULL,
    cli_telefono    VARCHAR(10),
    cli_celular     VARCHAR(10)   NOT NULL,
    cli_email       VARCHAR(80),
    id_ciudad       CHAR(3)       NOT NULL,
    cli_direccion   VARCHAR(120)  NOT NULL,
    cli_tipo        CHAR(3)       NOT NULL,
    cli_descuento   NUMERIC(6,4)  NOT NULL DEFAULT 0,
    cli_credito_max NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    estado_cli      CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_clientes         PRIMARY KEY (id_cliente),
    CONSTRAINT uq_cli_ruc_ced      UNIQUE      (cli_ruc_ced),
    CONSTRAINT fk_cli_ciudad       FOREIGN KEY (id_ciudad)
        REFERENCES ciudades(id_ciudad)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_cli_tipo        CHECK (cli_tipo     IN ('JUR','NAT')),
    CONSTRAINT chk_estado_cli      CHECK (estado_cli   IN ('ACT','INA')),
    CONSTRAINT chk_cli_descuento   CHECK (cli_descuento   BETWEEN 0 AND 100),
    CONSTRAINT chk_cli_credito_max CHECK (cli_credito_max >= 0),
    CONSTRAINT chk_cli_email       CHECK (cli_email LIKE '%@%.%' OR cli_email IS NULL),
    CONSTRAINT chk_cli_ruc_ced_len CHECK (LENGTH(TRIM(cli_ruc_ced)) IN (10,13))
);
COMMENT ON TABLE clientes IS 'Clientes de la empresa — base del módulo ventas';
COMMENT ON COLUMN clientes.cli_ruc_ced
    IS 'RUC (13 dígitos) o cédula (10 dígitos). Req #1: validar longitud.';


CREATE TABLE vendedores (
    id_vendedor  CHAR(7)       NOT NULL,
    ven_comision NUMERIC(6,4)  NOT NULL DEFAULT 0,
    ven_meta_mes NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    estado_ven   CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_vendedores    PRIMARY KEY (id_vendedor),
    CONSTRAINT fk_ven_empleado  FOREIGN KEY (id_vendedor)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_ven_comision CHECK (ven_comision BETWEEN 0 AND 100),
    CONSTRAINT chk_ven_meta     CHECK (ven_meta_mes >= 0),
    CONSTRAINT chk_estado_ven   CHECK (estado_ven   IN ('ACT','INA'))
);
COMMENT ON TABLE vendedores
    IS 'Vendedores: extensión 1:1 de empleados con porcentaje de comisión';
COMMENT ON COLUMN vendedores.id_vendedor
    IS 'FK 1:1 con empleados.id_empleado (patrón supertype/subtype)';


CREATE TABLE formas_pago (
    id_forma_pago     CHAR(3)     NOT NULL,
    fpa_descripcion   VARCHAR(30) NOT NULL,
    fpa_genera_cuotas BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT pk_formas_pago     PRIMARY KEY (id_forma_pago),
    CONSTRAINT uq_fpa_descripcion UNIQUE      (fpa_descripcion)
);
COMMENT ON TABLE formas_pago IS 'Catálogo de formas de pago: EFE|CHE|TAR|CRE';
COMMENT ON COLUMN formas_pago.fpa_genera_cuotas
    IS 'TRUE = requiere tabla cuotas_credito (solo para CRE)';

INSERT INTO formas_pago VALUES
    ('EFE', 'Efectivo',           FALSE),
    ('CHE', 'Cheque',             FALSE),
    ('TAR', 'Tarjeta de Crédito', FALSE),
    ('CRE', 'Crédito Directo',    TRUE);


-- --------------------------------------------------------------------
--  7.4  FACTURAS
--       fac_total: GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE facturas (
    id_factura      CHAR(7)       NOT NULL,
    fac_numero_sri  VARCHAR(17)   NOT NULL,
    id_cliente      CHAR(7)       NOT NULL,
    id_vendedor     CHAR(7)       NOT NULL,
    id_forma_pago   CHAR(3)       NOT NULL,
    id_entrega      CHAR(7),
    id_asiento      CHAR(7),
    fac_descripcion VARCHAR(200),
    fac_fecha       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fac_subtotal    NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    fac_descuento   NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    fac_iva         NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    fac_ice         NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    fac_total       NUMERIC(14,2) GENERATED ALWAYS AS
        (fac_subtotal - fac_descuento + fac_iva + fac_ice) STORED,
    estado_fac      CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_facturas        PRIMARY KEY (id_factura),
    CONSTRAINT uq_fac_numero_sri  UNIQUE      (fac_numero_sri),
    CONSTRAINT fk_fac_cliente     FOREIGN KEY (id_cliente)
        REFERENCES clientes(id_cliente)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_fac_vendedor    FOREIGN KEY (id_vendedor)
        REFERENCES vendedores(id_vendedor)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_fac_forma_pago  FOREIGN KEY (id_forma_pago)
        REFERENCES formas_pago(id_forma_pago)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_fac_entrega     FOREIGN KEY (id_entrega)
        REFERENCES entregas(id_entrega)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_fac_asiento     FOREIGN KEY (id_asiento)
        REFERENCES asientos(id_asiento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_fac     CHECK (estado_fac    IN ('ABI','APR','ANU')),
    CONSTRAINT chk_fac_subtotal   CHECK (fac_subtotal  >= 0),
    CONSTRAINT chk_fac_descuento  CHECK (fac_descuento >= 0),
    CONSTRAINT chk_fac_iva        CHECK (fac_iva       >= 0),
    CONSTRAINT chk_fac_ice        CHECK (fac_ice       >= 0)
);
COMMENT ON TABLE facturas IS 'Cabecera de Factura de Venta — ABI | APR | ANU';
COMMENT ON COLUMN facturas.fac_numero_sri
    IS 'Formato SRI: 001-002-0000001 (UNIQUE, auditable)';
COMMENT ON COLUMN facturas.fac_total
    IS 'GENERATED STORED: fac_subtotal - fac_descuento + fac_iva + fac_ice';


-- --------------------------------------------------------------------
--  7.5  FACTURA_DET
--       fad_subtotal: GENERATED STORED — ROUND() es determinista en PG.
-- --------------------------------------------------------------------
CREATE TABLE factura_det (
    id_factura       CHAR(7)       NOT NULL,
    fad_linea        INTEGER       NOT NULL,
    id_producto      CHAR(7)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    fad_cantidad     NUMERIC(12,4) NOT NULL,
    fad_precio_unit  NUMERIC(14,4) NOT NULL,
    fad_descuento_ln NUMERIC(6,4)  NOT NULL DEFAULT 0,
    fad_subtotal     NUMERIC(14,2) GENERATED ALWAYS AS (
        ROUND(fad_cantidad * fad_precio_unit * (1 - fad_descuento_ln / 100), 2)
    ) STORED,
    estado_fad       CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_factura_det       PRIMARY KEY (id_factura, fad_linea),
    CONSTRAINT fk_fad_factura       FOREIGN KEY (id_factura)
        REFERENCES facturas(id_factura)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_fad_producto      FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_fad_um            FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_fad       CHECK (estado_fad       IN ('ABI','APR','ANU')),
    CONSTRAINT chk_fad_cantidad     CHECK (fad_cantidad      > 0),
    CONSTRAINT chk_fad_precio_unit  CHECK (fad_precio_unit  >= 0),
    CONSTRAINT chk_fad_descuento_ln CHECK (fad_descuento_ln  BETWEEN 0 AND 100)
);
COMMENT ON TABLE factura_det IS 'Detalle de productos por Factura de Venta (req #4 #5 #10)';
COMMENT ON COLUMN factura_det.fad_subtotal
    IS 'GENERATED STORED: ROUND(qty × precio × (1 - desc%/100), 2)';


CREATE TABLE factura_pago (
    id_factura     CHAR(7)       NOT NULL,
    id_forma_pago  CHAR(3)       NOT NULL,
    fgp_valor      NUMERIC(14,2) NOT NULL,
    fgp_referencia VARCHAR(40),
    fgp_fecha      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_factura_pago   PRIMARY KEY (id_factura, id_forma_pago),
    CONSTRAINT fk_fgp_factura    FOREIGN KEY (id_factura)
        REFERENCES facturas(id_factura)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_fgp_forma_pago FOREIGN KEY (id_forma_pago)
        REFERENCES formas_pago(id_forma_pago)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_fgp_valor     CHECK (fgp_valor > 0)
);
COMMENT ON TABLE factura_pago
    IS 'Distribución de formas de pago por factura (split payment — req #7)';


-- --------------------------------------------------------------------
--  7.7  CUOTAS_CREDITO
--
--  DIFERENCIA IMPORTANTE vs. MySQL:
--  En PG, las columnas GENERATED ALWAYS AS no pueden referenciar
--  funciones volátiles como CURRENT_DATE. Por eso cuo_dias_mora
--  NO es una columna GENERATED aquí.
--
--  Solución PG 16: la columna se calcula en la VISTA v_cuotas_mora
--  (definida al final de este bloque) con la fórmula equivalente:
--      CASE WHEN cuo_fecha_pago IS NOT NULL
--           THEN cuo_fecha_pago::DATE - cuo_fecha_vence
--           ELSE CURRENT_DATE   - cuo_fecha_vence
--      END
--
--  cuo_numero: SMALLINT (reemplaza TINYINT UNSIGNED, rango suficiente 1-12)
-- --------------------------------------------------------------------
CREATE TABLE cuotas_credito (
    id_factura      CHAR(7)  NOT NULL,
    cuo_numero      SMALLINT NOT NULL,
    cuo_fecha_vence DATE     NOT NULL,
    cuo_valor       NUMERIC(14,2) NOT NULL,
    cuo_fecha_pago  TIMESTAMP,
    estado_cuo      CHAR(3)  NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_cuotas_credito PRIMARY KEY (id_factura, cuo_numero),
    CONSTRAINT fk_cuo_factura    FOREIGN KEY (id_factura)
        REFERENCES facturas(id_factura)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT chk_estado_cuo    CHECK (estado_cuo  IN ('PEN','PAG','VEN')),
    CONSTRAINT chk_cuo_numero    CHECK (cuo_numero  BETWEEN 1 AND 12),
    CONSTRAINT chk_cuo_valor     CHECK (cuo_valor   > 0)
);
COMMENT ON TABLE cuotas_credito
    IS 'Cuotas de crédito por factura — máx. 12 (req #3 #6 #7)';
COMMENT ON COLUMN cuotas_credito.cuo_fecha_pago
    IS 'NULL = pendiente de pago. NOT NULL = fecha en que se pagó.';

-- Vista que expone cuo_dias_mora calculado en tiempo de consulta
-- (equivalente al campo GENERATED que MySQL sí permite con CURDATE())
CREATE VIEW v_cuotas_mora AS
SELECT
    id_factura,
    cuo_numero,
    cuo_fecha_vence,
    cuo_valor,
    cuo_fecha_pago,
    estado_cuo,
    CASE
        WHEN cuo_fecha_pago IS NOT NULL
        THEN (cuo_fecha_pago::DATE  - cuo_fecha_vence)
        ELSE (CURRENT_DATE          - cuo_fecha_vence)
    END AS cuo_dias_mora
FROM cuotas_credito;

COMMENT ON VIEW v_cuotas_mora IS
    'Cuotas con días de mora calculados dinámicamente. '
    'En MySQL esto era una columna GENERATED con CURDATE(), '
    'incompatible con PG (función volátil). '
    'Usar esta vista para req #3 (tiempo de pago) y req #6/#7 (cartera/flujo).';


-- --------------------------------------------------------------------
--  7.8  DEVOLUCIONES
--       dev_total: GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE devoluciones (
    id_devolucion CHAR(7)       NOT NULL,
    id_factura    CHAR(7)       NOT NULL,
    id_empleado   CHAR(7)       NOT NULL,
    id_asiento    CHAR(7),
    dev_tipo      CHAR(3)       NOT NULL,
    dev_motivo    VARCHAR(200)  NOT NULL,
    dev_fecha     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dev_subtotal  NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    dev_iva       NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    dev_total     NUMERIC(14,2) GENERATED ALWAYS AS
        (dev_subtotal + dev_iva) STORED,
    estado_dev    CHAR(3)       NOT NULL DEFAULT 'PEN',
    CONSTRAINT pk_devoluciones   PRIMARY KEY (id_devolucion),
    CONSTRAINT fk_dev_factura    FOREIGN KEY (id_factura)
        REFERENCES facturas(id_factura)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_dev_empleado   FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_dev_asiento    FOREIGN KEY (id_asiento)
        REFERENCES asientos(id_asiento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_dev_tipo      CHECK (dev_tipo    IN ('TOT','PAR')),
    CONSTRAINT chk_estado_dev    CHECK (estado_dev  IN ('PEN','APR','ANU')),
    CONSTRAINT chk_dev_subtotal  CHECK (dev_subtotal >= 0),
    CONSTRAINT chk_dev_iva       CHECK (dev_iva      >= 0)
);
COMMENT ON TABLE devoluciones
    IS 'Cabecera de Devolución de Venta — TOT|PAR, PEN|APR|ANU';
COMMENT ON COLUMN devoluciones.dev_total
    IS 'GENERATED STORED: dev_subtotal + dev_iva';


-- --------------------------------------------------------------------
--  7.9  DEVOLUCION_DET
--       dvd_subtotal: GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE devolucion_det (
    id_devolucion    CHAR(7)       NOT NULL,
    dvd_linea        INTEGER       NOT NULL,
    id_producto      CHAR(7)       NOT NULL,
    id_unidad_medida CHAR(3)       NOT NULL,
    dvd_cantidad     NUMERIC(12,4) NOT NULL,
    dvd_precio_unit  NUMERIC(14,4) NOT NULL,
    dvd_subtotal     NUMERIC(14,2) GENERATED ALWAYS AS
        (ROUND(dvd_cantidad * dvd_precio_unit, 2)) STORED,
    dvd_motivo_lin   VARCHAR(200),
    CONSTRAINT pk_devolucion_det   PRIMARY KEY (id_devolucion, dvd_linea),
    CONSTRAINT fk_dvd_devolucion   FOREIGN KEY (id_devolucion)
        REFERENCES devoluciones(id_devolucion)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_dvd_producto     FOREIGN KEY (id_producto)
        REFERENCES productos(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_dvd_um           FOREIGN KEY (id_unidad_medida)
        REFERENCES unidades_medidas(id_unidad_medida)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_dvd_cantidad    CHECK (dvd_cantidad    > 0),
    CONSTRAINT chk_dvd_precio_unit CHECK (dvd_precio_unit >= 0)
);
COMMENT ON TABLE devolucion_det
    IS 'Detalle de líneas de Devolución por producto (req #5)';
COMMENT ON COLUMN devolucion_det.dvd_subtotal
    IS 'GENERATED STORED: ROUND(dvd_cantidad * dvd_precio_unit, 2)';


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE 8 — MÓDULO TALENTO HUMANO
--  Estrategia: empleados ya existe (Bloque 3). TTHH la extiende via ALTER.
-- ════════════════════════════════════════════════════════════════════════

-- --------------------------------------------------------------------
--  8.1  TIPO_CONTRATO — catálogo de modalidades
--       Se crea ANTES del ALTER porque empleados lo referencia.
-- --------------------------------------------------------------------
CREATE TABLE tipo_contrato (
    id_tipo_contrato CHAR(3)     NOT NULL,
    tco_descripcion  VARCHAR(40) NOT NULL,
    CONSTRAINT pk_tipo_contrato   PRIMARY KEY (id_tipo_contrato),
    CONSTRAINT uq_tco_descripcion UNIQUE      (tco_descripcion)
);
COMMENT ON TABLE tipo_contrato
    IS 'Modalidades de contrato laboral: TMP|PER|TER|PRO';

INSERT INTO tipo_contrato VALUES
    ('TMP', 'Temporal'),
    ('PER', 'Permanente'),
    ('TER', 'Tercerizado'),
    ('PRO', 'Servicios Profesionales');


-- --------------------------------------------------------------------
--  8.2  ALTER TABLE empleados — agregar atributos de TTHH
--       emp_sueldo        : NUMERIC (reemplaza DECIMAL de MySQL)
--       emp_sexo          : CHAR(1) con CHECK (igual que MySQL)
--       id_jefe           : auto-referencia → NULL = nivel máximo
-- --------------------------------------------------------------------
ALTER TABLE empleados
    ADD COLUMN emp_segundo_apellido VARCHAR(40),
    ADD COLUMN emp_segundo_nombre   VARCHAR(40),
    ADD COLUMN emp_fecha_nacimiento DATE,
    ADD COLUMN emp_sexo             CHAR(1),
    ADD COLUMN emp_email            VARCHAR(80),
    ADD COLUMN emp_telefono         VARCHAR(10),
    ADD COLUMN emp_celular          VARCHAR(10),
    ADD COLUMN emp_direccion        VARCHAR(120),
    ADD COLUMN emp_tipo_sangre      CHAR(3),
    ADD COLUMN emp_sueldo           NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    ADD COLUMN emp_banco            VARCHAR(50),
    ADD COLUMN emp_tipo_cuenta      CHAR(3),
    ADD COLUMN emp_cuenta_bancaria  VARCHAR(25),
    ADD COLUMN emp_foto             VARCHAR(200),
    ADD COLUMN emp_fecha_ingreso    DATE,
    ADD COLUMN id_tipo_contrato     CHAR(3),
    ADD COLUMN id_jefe              CHAR(7);

-- Constraints para las columnas nuevas
ALTER TABLE empleados
    ADD CONSTRAINT fk_emp_tipo_contrato FOREIGN KEY (id_tipo_contrato)
        REFERENCES tipo_contrato(id_tipo_contrato)
        ON UPDATE CASCADE ON DELETE SET NULL,
    ADD CONSTRAINT fk_emp_jefe          FOREIGN KEY (id_jefe)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE SET NULL,
    ADD CONSTRAINT chk_emp_sexo         CHECK (emp_sexo        IN ('M','F') OR emp_sexo IS NULL),
    ADD CONSTRAINT chk_emp_tipo_cuenta  CHECK (emp_tipo_cuenta IN ('CTA','AHO') OR emp_tipo_cuenta IS NULL),
    ADD CONSTRAINT chk_emp_tipo_sangre  CHECK (emp_tipo_sangre IN ('O+','O-','A+','A-','B+','B-','AB+','AB-') OR emp_tipo_sangre IS NULL),
    ADD CONSTRAINT chk_emp_sueldo       CHECK (emp_sueldo >= 0),
    ADD CONSTRAINT chk_emp_email_tthh   CHECK (emp_email LIKE '%@%.%' OR emp_email IS NULL);

COMMENT ON COLUMN empleados.emp_sueldo
    IS 'Sueldo base vigente. Req #3/#6: MIN/MAX/AVG por departamento.';
COMMENT ON COLUMN empleados.id_jefe
    IS 'Auto-referencia: jefe directo del empleado. NULL = nivel jerárquico máximo.';


CREATE TABLE centros_costo (
    id_centro       CHAR(5)       NOT NULL,
    id_departamento CHAR(3)       NOT NULL,
    cco_descripcion VARCHAR(60)   NOT NULL,
    cco_presupuesto NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    estado_cco      CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_centros_costo    PRIMARY KEY (id_centro),
    CONSTRAINT uq_cco_descripcion  UNIQUE      (id_departamento, cco_descripcion),
    CONSTRAINT fk_cco_departamento FOREIGN KEY (id_departamento)
        REFERENCES departamentos(id_departamento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_cco      CHECK (estado_cco      IN ('ACT','INA')),
    CONSTRAINT chk_cco_presupuesto CHECK (cco_presupuesto >= 0)
);
COMMENT ON TABLE centros_costo
    IS 'Centros de costo dentro de cada departamento';


-- --------------------------------------------------------------------
--  8.4  CONCEPTOS_NOMINA
--       con_es_fijo: BOOLEAN (reemplaza TINYINT(1))
-- --------------------------------------------------------------------
CREATE TABLE conceptos_nomina (
    id_concepto     CHAR(4)      NOT NULL,
    con_descripcion VARCHAR(60)  NOT NULL,
    con_tipo        CHAR(3)      NOT NULL,
    con_es_fijo     BOOLEAN      NOT NULL DEFAULT TRUE,
    con_porcentaje  NUMERIC(6,4) NOT NULL DEFAULT 0,
    estado_con      CHAR(3)      NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_conceptos_nomina PRIMARY KEY (id_concepto),
    CONSTRAINT uq_con_descripcion  UNIQUE      (con_descripcion),
    CONSTRAINT chk_con_tipo        CHECK (con_tipo       IN ('ING','DES')),
    CONSTRAINT chk_estado_con      CHECK (estado_con     IN ('ACT','INA')),
    CONSTRAINT chk_con_porcentaje  CHECK (con_porcentaje BETWEEN 0 AND 100)
);
COMMENT ON TABLE conceptos_nomina
    IS 'Catálogo de conceptos de nómina: ingresos (ING) y descuentos (DES)';
COMMENT ON COLUMN conceptos_nomina.id_concepto
    IS 'Código 1000-9999: 1xxx = ingresos, 2xxx = descuentos';
COMMENT ON COLUMN conceptos_nomina.con_es_fijo
    IS 'TRUE = monto fijo mensual; FALSE = variable, se ingresa manualmente';

INSERT INTO conceptos_nomina VALUES
    ('1000','Sueldo Mensual',           'ING', TRUE,  0,     'ACT'),
    ('1020','Fondo de Reserva',         'ING', TRUE,  8.33,  'ACT'),
    ('2000','Aporte personal IESS',     'DES', TRUE,  9.45,  'ACT'),
    ('2003','Cesantía Personal APPUCE', 'DES', TRUE,  2.00,  'ACT'),
    ('2004','Aporte Fideicomiso',       'DES', TRUE,  3.86,  'ACT'),
    ('2005','Aporte seguro médico',     'DES', TRUE,  1.19,  'ACT'),
    ('2006','Seguro vida',              'DES', TRUE,  1.42,  'ACT'),
    ('2007','Aporte APPUCE',            'DES', TRUE,  2.00,  'ACT'),
    ('2010','Préstamo APPUCE',          'DES', FALSE, 0,     'ACT'),
    ('2021','Impuesto a la renta',      'DES', FALSE, 0,     'ACT');


-- --------------------------------------------------------------------
--  8.5  ROL_PAGOS
--       rpl_anio  : SMALLINT (reemplaza SMALLINT UNSIGNED)
--       rpl_mes   : SMALLINT (reemplaza TINYINT UNSIGNED)
--       rpl_neto  : GENERATED STORED — determinista, válida en PG.
-- --------------------------------------------------------------------
CREATE TABLE rol_pagos (
    id_rol_pago          CHAR(7)       NOT NULL,
    id_empleado          CHAR(7)       NOT NULL,
    id_centro            CHAR(5),
    id_asiento           CHAR(7),
    rpl_anio             SMALLINT      NOT NULL,
    rpl_mes              SMALLINT      NOT NULL,
    rpl_sueldo_base      NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    rpl_total_ingresos   NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    rpl_total_descuentos NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    rpl_neto             NUMERIC(14,2) GENERATED ALWAYS AS
        (rpl_total_ingresos - rpl_total_descuentos) STORED,
    rpl_fecha_pago       DATE,
    estado_rpl           CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_rol_pagos              PRIMARY KEY (id_rol_pago),
    CONSTRAINT uq_rol_emp_periodo        UNIQUE      (id_empleado, rpl_anio, rpl_mes),
    CONSTRAINT fk_rpl_empleado           FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_rpl_centro             FOREIGN KEY (id_centro)
        REFERENCES centros_costo(id_centro)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_rpl_asiento            FOREIGN KEY (id_asiento)
        REFERENCES asientos(id_asiento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_estado_rpl            CHECK (estado_rpl           IN ('ABI','APR','ANU')),
    CONSTRAINT chk_rpl_mes               CHECK (rpl_mes              BETWEEN 1 AND 12),
    CONSTRAINT chk_rpl_sueldo_base       CHECK (rpl_sueldo_base      >= 0),
    CONSTRAINT chk_rpl_total_ingresos    CHECK (rpl_total_ingresos   >= 0),
    CONSTRAINT chk_rpl_total_descuentos  CHECK (rpl_total_descuentos >= 0)
);
COMMENT ON TABLE rol_pagos
    IS 'Cabecera de Rol de Pagos por empleado y período (req #8 #9 #10)';
COMMENT ON COLUMN rol_pagos.rpl_neto
    IS 'GENERATED STORED: rpl_total_ingresos - rpl_total_descuentos';
COMMENT ON COLUMN rol_pagos.rpl_sueldo_base
    IS 'Snapshot del sueldo base al generar el rol (no cambia si sube el sueldo)';


CREATE TABLE rol_pagos_det (
    id_rol_pago  CHAR(7)       NOT NULL,
    rpd_linea    INTEGER       NOT NULL,
    id_concepto  CHAR(4)       NOT NULL,
    rpd_tipo     CHAR(3)       NOT NULL,
    rpd_cantidad NUMERIC(10,4) NOT NULL DEFAULT 1,
    rpd_valor    NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    estado_rpd   CHAR(3)       NOT NULL DEFAULT 'ABI',
    CONSTRAINT pk_rol_pagos_det PRIMARY KEY (id_rol_pago, rpd_linea),
    CONSTRAINT fk_rpd_rol       FOREIGN KEY (id_rol_pago)
        REFERENCES rol_pagos(id_rol_pago)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_rpd_concepto  FOREIGN KEY (id_concepto)
        REFERENCES conceptos_nomina(id_concepto)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_rpd_tipo     CHECK (rpd_tipo    IN ('ING','DES')),
    CONSTRAINT chk_estado_rpd   CHECK (estado_rpd  IN ('ABI','APR','ANU')),
    CONSTRAINT chk_rpd_cantidad CHECK (rpd_cantidad >  0),
    CONSTRAINT chk_rpd_valor    CHECK (rpd_valor    >= 0)
);
COMMENT ON TABLE rol_pagos_det
    IS 'Detalle de conceptos de nómina por rol de pagos (req #9)';
COMMENT ON COLUMN rol_pagos_det.rpd_tipo
    IS 'ING | DES — denormalizado para reportes sin JOIN adicional';


CREATE TABLE cargas_familiares (
    id_carga             CHAR(7)       NOT NULL,
    id_empleado          CHAR(7)       NOT NULL,
    car_cedula           VARCHAR(13),
    car_apellidos        VARCHAR(60)   NOT NULL,
    car_nombres          VARCHAR(60)   NOT NULL,
    car_fecha_nacimiento DATE          NOT NULL,
    car_sexo             CHAR(1)       NOT NULL,
    car_parentesco       CHAR(3)       NOT NULL,
    car_estado_civil     CHAR(3),
    car_es_dependiente   BOOLEAN       NOT NULL DEFAULT TRUE,
    estado_car           CHAR(3)       NOT NULL DEFAULT 'ACT',
    CONSTRAINT pk_cargas_familiares  PRIMARY KEY (id_carga),
    CONSTRAINT fk_car_empleado       FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_car_sexo          CHECK (car_sexo        IN ('M','F')),
    CONSTRAINT chk_car_parentesco    CHECK (car_parentesco  IN ('CON','HIJ','PAD','MAD','OTR')),
    CONSTRAINT chk_car_estado_civil  CHECK (car_estado_civil IN ('SOL','CAS','DIV','VIU') OR car_estado_civil IS NULL),
    CONSTRAINT chk_estado_car        CHECK (estado_car      IN ('ACT','INA'))
);
COMMENT ON TABLE cargas_familiares
    IS 'Cargas familiares del empleado (req #1: menores para regalo; req #4: evento)';
COMMENT ON COLUMN cargas_familiares.car_fecha_nacimiento
    IS 'Req #1 #4: calcular edad para regalos navideños y Día del Niño';


-- --------------------------------------------------------------------
--  8.8  HISTORIAL_CARGO — tabla append-only
--       id_historial: BIGINT GENERATED ALWAYS AS IDENTITY.
--       hca_incremento: GENERATED STORED — determinista.
-- --------------------------------------------------------------------
CREATE TABLE historial_cargo (
    id_historial        BIGINT        NOT NULL GENERATED ALWAYS AS IDENTITY,
    id_empleado         CHAR(7)       NOT NULL,
    hca_tipo            CHAR(3)       NOT NULL,
    id_rol_anterior     CHAR(3),
    id_rol_nuevo        CHAR(3)       NOT NULL,
    id_dpto_anterior    CHAR(3),
    id_dpto_nuevo       CHAR(3)       NOT NULL,
    hca_sueldo_anterior NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    hca_sueldo_nuevo    NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    hca_incremento      NUMERIC(14,2) GENERATED ALWAYS AS
        (hca_sueldo_nuevo - hca_sueldo_anterior) STORED,
    hca_fecha           DATE          NOT NULL,
    hca_motivo          VARCHAR(200),
    hca_registrado_por  CHAR(7),
    CONSTRAINT pk_historial_cargo     PRIMARY KEY (id_historial),
    CONSTRAINT fk_hca_empleado        FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_hca_rol_anterior    FOREIGN KEY (id_rol_anterior)
        REFERENCES roles(id_rol)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_hca_rol_nuevo       FOREIGN KEY (id_rol_nuevo)
        REFERENCES roles(id_rol)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_hca_dpto_anterior   FOREIGN KEY (id_dpto_anterior)
        REFERENCES departamentos(id_departamento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_hca_dpto_nuevo      FOREIGN KEY (id_dpto_nuevo)
        REFERENCES departamentos(id_departamento)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_hca_registrado_por  FOREIGN KEY (hca_registrado_por)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_hca_tipo              CHECK (hca_tipo            IN ('ASC','TRF','AUM','CAP','OTR')),
    CONSTRAINT chk_hca_sueldo_anterior   CHECK (hca_sueldo_anterior >= 0),
    CONSTRAINT chk_hca_sueldo_nuevo      CHECK (hca_sueldo_nuevo    >= 0)
);
COMMENT ON TABLE historial_cargo
    IS 'Historial de cargos, traslados y aumentos del empleado — append-only';
COMMENT ON COLUMN historial_cargo.hca_incremento
    IS 'GENERATED STORED: hca_sueldo_nuevo - hca_sueldo_anterior. + aumento / - reducción';
COMMENT ON COLUMN historial_cargo.id_historial
    IS 'BIGINT GENERATED ALWAYS AS IDENTITY — tabla append-only, jamás se actualiza';


-- --------------------------------------------------------------------
--  8.9  ASISTENCIAS — registro diario append-only
--       id_asistencia: BIGINT GENERATED ALWAYS AS IDENTITY.
--       asi_justificada: BOOLEAN.
-- --------------------------------------------------------------------
CREATE TABLE asistencias (
    id_asistencia    BIGINT      NOT NULL GENERATED ALWAYS AS IDENTITY,
    id_empleado      CHAR(7)     NOT NULL,
    asi_fecha        DATE        NOT NULL,
    asi_tipo         CHAR(3)     NOT NULL DEFAULT 'PRE',
    asi_hora_entrada TIME,
    asi_hora_salida  TIME,
    asi_justificada  BOOLEAN     NOT NULL DEFAULT FALSE,
    asi_observacion  VARCHAR(200),
    CONSTRAINT pk_asistencias          PRIMARY KEY (id_asistencia),
    CONSTRAINT uq_asistencia_emp_fecha UNIQUE      (id_empleado, asi_fecha),
    CONSTRAINT fk_asi_empleado         FOREIGN KEY (id_empleado)
        REFERENCES empleados(id_empleado)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_asi_tipo            CHECK (asi_tipo IN ('PRE','AUS','TAR','VAC'))
);
COMMENT ON TABLE asistencias
    IS 'Registro diario de asistencias — append-only (req #7: faltas injustificadas)';
COMMENT ON COLUMN asistencias.asi_justificada
    IS 'TRUE = inasistencia/tardanza justificada; FALSE = injustificada';
COMMENT ON COLUMN asistencias.id_asistencia
    IS 'BIGINT GENERATED ALWAYS AS IDENTITY — append-only, correcciones son nuevas filas';


-- ████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT DDL — PostgreSQL 16
-- ────────────────────────────────────────────────────────────────────────
--  RESUMEN:
--    Tablas              : 50
--    Vistas              :  1  (v_cuotas_mora)
--    Funciones trigger   :  2  (fn_validar_partida_doble, fn_set_update_timestamp)
--    Triggers            :  3  (asi_ins, asi_upd, stk_upd)
--    Tipos ENUM          :  1  (tipo_operacion_dml)
--    Foreign Keys        : 86
--    CHECK constraints   :123
--    Columnas GENERATED  : 11  (todas deterministas — válidas en PG 12+)
--
--  CONTINUAR CON: COMERCIAL_INDEXES_PG16.sql
-- ████████████████████████████████████████████████████████████████████████
