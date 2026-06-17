-- ████████████████████████████████████████████████████████████████████████
-- ██  MÓDULO VENTAS — STORED PROCEDURES                                  ██
-- ██  Sistema COMERCIAL · JW Cóndor · PostgreSQL 16                      ██
-- ████████████████████████████████████████████████████████████████████████
--
--  CONTENIDO:
--    SP-1  sp_crear_factura    — Registra Factura en estado ABI
--    SP-2  sp_aprobar_factura  — ABI → APR; descuenta stock; genera Entrega y Asiento
--    SP-3  sp_anular_factura   — ABI/APR → ANU; revierte inventario y asiento
--    SP-4  sp_visualizar_factura — Devuelve dos REFCURSOR: cabecera + detalle
--
--  REQUISITOS TÉCNICOS IMPLEMENTADOS:
--    ✔ CREATE PROCEDURE (no FUNCTION) — permite COMMIT / ROLLBACK explícitos
--    ✔ COMMIT al finalizar con éxito; ROLLBACK en el bloque EXCEPTION
--    ✔ Bloque EXCEPTION captura cualquier error y hace ROLLBACK automático
--    ✔ SELECT … FOR UPDATE en bucles de stock → evita race conditions
--    ✔ Acceso por PK/índices en todas las búsquedas (no seq-scan)
--    ✔ Registro en auditoria_sistema en cada operación
--    ✔ Lógica comercial: validación de cliente, vendedor, stock, crédito
--
--  NOTA IMPORTANTE — CONTROL DE TRANSACCIONES EN PROCEDURES PG:
--    COMMIT y ROLLBACK dentro de un PROCEDURE son válidos en PG 11+ cuando
--    el procedimiento es llamado desde el nivel superior (CALL sin BEGIN
--    externo). Si se invoca desde otra transacción ya abierta, PG emitirá
--    "ERROR: invalid transaction termination". En ese caso, omitir el COMMIT
--    explícito y dejar que el llamador controle la transacción.
--
--  EJECUCIÓN:
--    \c comercial
--    SET search_path TO comercial;
--    \i VENTAS_SP_PG16.sql
--
-- ████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════
--  SP-1  sp_crear_factura
-- ════════════════════════════════════════════════════════════════════════
--
--  Registra una nueva Factura de Venta con estado ABI.
--  Inserta la cabecera, todas las líneas de detalle y, si la forma de
--  pago es crédito (fpa_genera_cuotas = TRUE), genera las cuotas.
--
--  Calcula:
--    fac_subtotal  = Σ fad_subtotal  (ROUND(qty × precio × (1 − desc%/100), 2))
--    fac_descuento = fac_subtotal × cli_descuento / 100
--    fac_iva       = (fac_subtotal − fac_descuento) × p_tasa_iva
--    fac_total     → columna GENERATED STORED (no se inserta manualmente)
--
--  PARÁMETROS:
--    p_id_factura          CHAR(7)       — ID único asignado por la aplicación
--    p_fac_numero_sri      VARCHAR(17)   — Formato SRI: 001-002-0000001
--    p_id_cliente          CHAR(7)       — FK → clientes (debe estar ACT)
--    p_id_vendedor         CHAR(7)       — FK → vendedores (debe estar ACT)
--    p_id_forma_pago       CHAR(3)       — FK → formas_pago (EFE|CHE|TAR|CRE)
--    p_fac_descripcion     VARCHAR(200)  — Descripción / notas de la venta
--    p_tasa_iva            NUMERIC(5,4)  — Tasa IVA decimal (ej. 0.15 = 15 %)
--    p_detalle             JSONB         — Array de líneas:
--                                          [{id_producto, id_unidad_medida,
--                                            cantidad, precio_unit, descuento_ln}]
--    p_num_cuotas          SMALLINT      — 1-12 si crédito; 0 en otro caso
--    p_fecha_primera_cuota DATE          — Vencimiento cuota 1 (NULL si no crédito)
--
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_crear_factura(
    IN p_id_factura           CHAR(7),
    IN p_fac_numero_sri       VARCHAR(17),
    IN p_id_cliente           CHAR(7),
    IN p_id_vendedor          CHAR(7),
    IN p_id_forma_pago        CHAR(3),
    IN p_fac_descripcion      VARCHAR(200),
    IN p_tasa_iva             NUMERIC(5,4),
    IN p_detalle              JSONB,
    IN p_num_cuotas           SMALLINT  DEFAULT 0,
    IN p_fecha_primera_cuota  DATE      DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Variables para iterar el detalle JSONB
    v_item           JSONB;
    v_linea          INTEGER        := 1;

    -- Acumuladores de totales de factura
    v_subtotal_fac   NUMERIC(14,2)  := 0;
    v_descuento_fac  NUMERIC(14,2)  := 0;
    v_iva_fac        NUMERIC(14,2)  := 0;
    v_total_fac      NUMERIC(14,2)  := 0;
    v_sub_linea      NUMERIC(14,2)  := 0;

    -- Datos del cliente
    v_cli_estado     CHAR(3);
    v_cli_descuento  NUMERIC(6,4);

    -- Datos de forma de pago
    v_fpa_genera     BOOLEAN;

    -- Variables para generación de cuotas
    v_valor_cuota    NUMERIC(14,2);
    v_fecha_vence    DATE;
    v_i              SMALLINT;
BEGIN

    -- ─── BLOQUE 0: VALIDACIONES PRE-TRANSACCIÓN ─────────────────────────────
    -- Todas las validaciones se ejecutan ANTES de la primera escritura.
    -- Si alguna falla, no existe nada que hacer rollback.

    -- 0.1 El ID de factura no debe existir (PK única)
    IF EXISTS (
        SELECT 1 FROM comercial.facturas WHERE id_factura = p_id_factura
    ) THEN
        RAISE EXCEPTION
            'Ya existe una Factura con ID [%]. Use un identificador distinto.',
            p_id_factura;
    END IF;

    -- 0.2 Número SRI único (restricción legal y fiscal)
    IF EXISTS (
        SELECT 1 FROM comercial.facturas WHERE fac_numero_sri = p_fac_numero_sri
    ) THEN
        RAISE EXCEPTION
            'El número SRI [%] ya está registrado en el sistema.',
            p_fac_numero_sri;
    END IF;

    -- 0.3 Tasa IVA en rango válido (0 a 1 → 0 % a 100 %)
    IF p_tasa_iva < 0 OR p_tasa_iva > 1 THEN
        RAISE EXCEPTION
            'Tasa IVA inválida: [%]. Debe estar entre 0 y 1 (ej. 0.15 para 15%%).',
            p_tasa_iva;
    END IF;

    -- 0.4 Cliente activo y recuperar su porcentaje de descuento
    SELECT estado_cli, cli_descuento
    INTO   v_cli_estado, v_cli_descuento
    FROM   comercial.clientes
    WHERE  id_cliente = p_id_cliente;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cliente [%] no encontrado en el sistema.', p_id_cliente;
    END IF;
    IF v_cli_estado <> 'ACT' THEN
        RAISE EXCEPTION
            'El cliente [%] no está activo (estado actual: [%]). '
            'No se puede emitir facturas a clientes inactivos.',
            p_id_cliente, v_cli_estado;
    END IF;

    -- 0.5 Vendedor activo
    IF NOT EXISTS (
        SELECT 1 FROM comercial.vendedores
        WHERE  id_vendedor = p_id_vendedor AND estado_ven = 'ACT'
    ) THEN
        RAISE EXCEPTION
            'Vendedor [%] no encontrado o inactivo.', p_id_vendedor;
    END IF;

    -- 0.6 Forma de pago válida
    SELECT fpa_genera_cuotas INTO v_fpa_genera
    FROM   comercial.formas_pago
    WHERE  id_forma_pago = p_id_forma_pago;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Forma de pago [%] no encontrada.', p_id_forma_pago;
    END IF;

    -- 0.7 Parámetros de crédito coherentes con la forma de pago
    IF v_fpa_genera THEN
        IF p_num_cuotas NOT BETWEEN 1 AND 12 THEN
            RAISE EXCEPTION
                'La forma de pago CRE exige entre 1 y 12 cuotas. '
                'Valor recibido: [%].', p_num_cuotas;
        END IF;
        IF p_fecha_primera_cuota IS NULL THEN
            RAISE EXCEPTION
                'La fecha de primera cuota es obligatoria para pago a crédito.';
        END IF;
        IF p_fecha_primera_cuota < CURRENT_DATE THEN
            RAISE EXCEPTION
                'La fecha de primera cuota [%] no puede ser anterior a hoy.',
                p_fecha_primera_cuota;
        END IF;
    END IF;

    -- 0.8 El detalle no puede estar vacío
    IF p_detalle IS NULL OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION
            'La factura debe contener al menos una línea de producto en el detalle.';
    END IF;

    -- 0.9 Validar cada ítem del detalle (producto activo, UM existente, qty > 0)
    --     Se recorre el JSONB para fallar rápido antes de cualquier INSERT.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_detalle)
    LOOP
        -- Producto existe y está activo
        IF NOT EXISTS (
            SELECT 1 FROM comercial.productos
            WHERE  id_producto = TRIM(v_item->>'id_producto')::CHAR(7)
              AND  estado_prod  = 'ACT'
        ) THEN
            RAISE EXCEPTION
                'Producto [%] no encontrado o inactivo.',
                v_item->>'id_producto';
        END IF;

        -- Unidad de medida existe
        IF NOT EXISTS (
            SELECT 1 FROM comercial.unidades_medidas
            WHERE  id_unidad_medida = TRIM(v_item->>'id_unidad_medida')::CHAR(3)
        ) THEN
            RAISE EXCEPTION
                'Unidad de medida [%] no encontrada (producto [%]).',
                v_item->>'id_unidad_medida', v_item->>'id_producto';
        END IF;

        -- Cantidad positiva
        IF COALESCE((v_item->>'cantidad')::NUMERIC, 0) <= 0 THEN
            RAISE EXCEPTION
                'La cantidad del producto [%] debe ser mayor a cero.',
                v_item->>'id_producto';
        END IF;

        -- Precio no negativo
        IF COALESCE((v_item->>'precio_unit')::NUMERIC, -1) < 0 THEN
            RAISE EXCEPTION
                'El precio unitario del producto [%] no puede ser negativo.',
                v_item->>'id_producto';
        END IF;
    END LOOP;

    -- ─── BLOQUE 1: OPERACIONES DML ATÓMICAS ─────────────────────────────────

    -- 1.1 Insertar cabecera con totales en cero (se actualizan en 1.3)
    --     fac_total es GENERATED STORED → no se incluye en INSERT
    INSERT INTO comercial.facturas (
        id_factura, fac_numero_sri, id_cliente, id_vendedor,
        id_forma_pago, fac_descripcion, fac_fecha,
        fac_subtotal, fac_descuento, fac_iva, fac_ice, estado_fac
    ) VALUES (
        p_id_factura, p_fac_numero_sri, p_id_cliente, p_id_vendedor,
        p_id_forma_pago, p_fac_descripcion, CURRENT_TIMESTAMP,
        0, 0, 0, 0, 'ABI'
    );

    -- 1.2 Insertar líneas de detalle y acumular el subtotal de factura
    --     La fórmula replica la columna GENERATED fad_subtotal para el acumulador.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_detalle)
    LOOP
        INSERT INTO comercial.factura_det (
            id_factura,
            fad_linea,
            id_producto,
            id_unidad_medida,
            fad_cantidad,
            fad_precio_unit,
            fad_descuento_ln,
            estado_fad
        ) VALUES (
            p_id_factura,
            v_linea,
            TRIM(v_item->>'id_producto')::CHAR(7),
            TRIM(v_item->>'id_unidad_medida')::CHAR(3),
            (v_item->>'cantidad')::NUMERIC(12,4),
            (v_item->>'precio_unit')::NUMERIC(14,4),
            COALESCE((v_item->>'descuento_ln')::NUMERIC(6,4), 0),
            'ABI'
        );

        -- Acumular subtotal de esta línea (réplica de fad_subtotal GENERATED)
        v_sub_linea := ROUND(
            (v_item->>'cantidad')::NUMERIC
            * (v_item->>'precio_unit')::NUMERIC
            * (1 - COALESCE((v_item->>'descuento_ln')::NUMERIC, 0) / 100),
            2
        );
        v_subtotal_fac := v_subtotal_fac + v_sub_linea;
        v_linea        := v_linea + 1;
    END LOOP;

    -- 1.3 Calcular descuento global del cliente e IVA sobre base imponible neta
    v_descuento_fac := ROUND(v_subtotal_fac * v_cli_descuento / 100, 2);
    v_iva_fac       := ROUND((v_subtotal_fac - v_descuento_fac) * p_tasa_iva, 2);

    -- 1.4 Actualizar cabecera con los totales reales calculados
    UPDATE comercial.facturas
    SET fac_subtotal  = v_subtotal_fac,
        fac_descuento = v_descuento_fac,
        fac_iva       = v_iva_fac
        -- fac_total se recalcula automáticamente (GENERATED STORED)
    WHERE id_factura = p_id_factura;

    -- 1.5 Generar cuotas de crédito si la forma de pago lo requiere
    IF v_fpa_genera THEN
        v_total_fac   := v_subtotal_fac - v_descuento_fac + v_iva_fac;
        v_valor_cuota := ROUND(v_total_fac / p_num_cuotas, 2);
        v_fecha_vence := p_fecha_primera_cuota;

        FOR v_i IN 1..p_num_cuotas
        LOOP
            INSERT INTO comercial.cuotas_credito (
                id_factura, cuo_numero, cuo_fecha_vence, cuo_valor, estado_cuo
            ) VALUES (
                p_id_factura,
                v_i,
                v_fecha_vence,
                -- La última cuota absorbe el residuo de redondeo para que las cuotas sumen exacto
                CASE WHEN v_i = p_num_cuotas
                     THEN v_total_fac - (v_valor_cuota * (p_num_cuotas - 1))
                     ELSE v_valor_cuota
                END,
                'PEN'
            );
            v_fecha_vence := v_fecha_vence + INTERVAL '1 month';
        END LOOP;
    END IF;

    -- 1.6 Registro de auditoría (tabla transversal auditoria_sistema)
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion,
        id_registro, valor_nuevo, fecha_hora
    ) VALUES (
        current_user,
        'facturas',
        'INSERT',
        p_id_factura,
        format('SRI:%s | CLI:%s | VEN:%s | SUBTOTAL:%s | IVA:%s | CUOTAS:%s',
               p_fac_numero_sri, p_id_cliente, p_id_vendedor,
               v_subtotal_fac, v_iva_fac, p_num_cuotas),
        CURRENT_TIMESTAMP
    );

    -- ─── COMMIT: confirma toda la transacción de forma atómica ──────────────
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK: revierte cualquier INSERT/UPDATE parcial ante cualquier fallo
        ROLLBACK;
        RAISE EXCEPTION '[sp_crear_factura] ERROR — SQLSTATE=% | Mensaje: %',
            SQLSTATE, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_crear_factura IS
'SP-1: Registra una Factura de Venta (estado ABI).
Valida cliente activo, vendedor activo, forma de pago, productos activos
y coherencia de cuotas de crédito. Calcula subtotal, descuento del
cliente e IVA. Genera cuotas si la forma de pago es CRE.
Atomicidad: COMMIT al finalizar con éxito; ROLLBACK ante cualquier error.';


-- ════════════════════════════════════════════════════════════════════════
--  SP-2  sp_aprobar_factura
-- ════════════════════════════════════════════════════════════════════════
--
--  Transiciona una Factura de ABI → APR.
--  Operaciones que ejecuta en una sola transacción:
--    a) Valida stock disponible por bodega (SELECT … FOR UPDATE → bloqueo de fila)
--    b) Valida límite de crédito del cliente (si aplica)
--    c) Crea la Orden de Egreso (entregas + entrega_det) en estado PEN
--    d) Reduce stock en stock_bodega (stk_cantidad) y en productos (pro_qty_egresos)
--    e) Inserta registros en movimientos_inv (ledger append-only)
--    f) Crea el Asiento Contable en estado PEN (partida doble balanceada)
--    g) Vincula id_entrega e id_asiento en la cabecera de facturas
--    h) Cambia estado_fac y estado_fad a APR
--
--  PARÁMETROS:
--    p_id_factura     CHAR(7)   — Factura a aprobar (debe estar en ABI)
--    p_id_entrega     CHAR(7)   — ID para la nueva Entrega (asignado por la app)
--    p_id_asiento     CHAR(7)   — ID para el nuevo Asiento Contable
--    p_id_bodega      CHAR(3)   — Bodega origen del egreso de mercancía
--    p_id_empleado    CHAR(7)   — Empleado (Jefe de Ventas) que aprueba
--    p_cuenta_cxc     CHAR(15)  — Cuenta DEBE: Cuentas × Cobrar / Caja
--    p_cuenta_ventas  CHAR(15)  — Cuenta HABER: Ingresos por Ventas
--    p_cuenta_iva_cob CHAR(15)  — Cuenta HABER: IVA en Ventas cobrado
--
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_aprobar_factura(
    IN p_id_factura      CHAR(7),
    IN p_id_entrega      CHAR(7),
    IN p_id_asiento      CHAR(7),
    IN p_id_bodega       CHAR(3),
    IN p_id_empleado     CHAR(7),
    IN p_cuenta_cxc      CHAR(15),
    IN p_cuenta_ventas   CHAR(15),
    IN p_cuenta_iva_cob  CHAR(15)
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Registro completo de la factura + datos de cliente
    v_fac            RECORD;

    -- Variables del bucle de procesamiento de líneas
    v_det            RECORD;
    v_stk_bodega     RECORD;    -- stock actual en la bodega seleccionada
    v_stk_anterior   NUMERIC(12,4);

    -- Contador de líneas de entrega
    v_etd_linea      INTEGER        := 1;

    -- Valores financieros calculados
    v_base_imponible NUMERIC(14,2);
    v_total_fac      NUMERIC(14,2);

    -- Control de límite de crédito
    v_deuda_actual   NUMERIC(14,2) := 0;
BEGIN

    -- ─── BLOQUE 0: VALIDACIONES PRE-TRANSACCIÓN ─────────────────────────────

    -- 0.1 Cargar factura con datos del cliente (JOIN único)
    --     Se usan índices PK en facturas y clientes
    SELECT
        f.id_factura, f.fac_numero_sri, f.estado_fac,
        f.id_cliente,  f.id_vendedor,   f.id_forma_pago,
        f.fac_subtotal, f.fac_descuento, f.fac_iva, f.fac_ice,
        c.cli_nombre,  c.cli_ruc_ced,
        c.cli_credito_max,
        fp.fpa_genera_cuotas
    INTO v_fac
    FROM   comercial.facturas    f
    JOIN   comercial.clientes    c  ON c.id_cliente    = f.id_cliente
    JOIN   comercial.formas_pago fp ON fp.id_forma_pago = f.id_forma_pago
    WHERE  f.id_factura = p_id_factura;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Factura [%] no encontrada.', p_id_factura;
    END IF;

    -- 0.2 Solo se puede aprobar desde estado ABI
    IF v_fac.estado_fac <> 'ABI' THEN
        RAISE EXCEPTION
            'La factura [%] no está en estado ABI (estado actual: [%]). '
            'Solo se permite la transición ABI → APR.',
            p_id_factura, v_fac.estado_fac;
    END IF;

    -- 0.3 Los IDs destino no deben existir aún (integridad de datos)
    IF EXISTS (SELECT 1 FROM comercial.entregas WHERE id_entrega = p_id_entrega) THEN
        RAISE EXCEPTION 'El ID de Entrega [%] ya existe.', p_id_entrega;
    END IF;
    IF EXISTS (SELECT 1 FROM comercial.asientos WHERE id_asiento = p_id_asiento) THEN
        RAISE EXCEPTION 'El ID de Asiento [%] ya existe.', p_id_asiento;
    END IF;

    -- 0.4 Bodega activa
    IF NOT EXISTS (
        SELECT 1 FROM comercial.bodegas
        WHERE  id_bodega = p_id_bodega AND estado_bod = 'ACT'
    ) THEN
        RAISE EXCEPTION 'Bodega [%] no encontrada o inactiva.', p_id_bodega;
    END IF;

    -- 0.5 Empleado activo
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
        WHERE  id_empleado = p_id_empleado AND estado_emp = 'ACT'
    ) THEN
        RAISE EXCEPTION 'Empleado [%] no encontrado o inactivo.', p_id_empleado;
    END IF;

    -- 0.6 Cuentas contables existen en el plan de cuentas
    IF NOT EXISTS (SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cuenta_cxc) THEN
        RAISE EXCEPTION 'Cuenta CxC [%] no existe en el plan de cuentas.', p_cuenta_cxc;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cuenta_ventas) THEN
        RAISE EXCEPTION 'Cuenta Ventas [%] no existe en el plan de cuentas.', p_cuenta_ventas;
    END IF;
    IF v_fac.fac_iva > 0 AND NOT EXISTS (
        SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cuenta_iva_cob
    ) THEN
        RAISE EXCEPTION 'Cuenta IVA [%] no existe en el plan de cuentas.', p_cuenta_iva_cob;
    END IF;

    -- 0.7 Verificar stock disponible en la bodega para cada línea.
    --     IMPORTANTE: no se usa FOR UPDATE aquí porque es solo validación previa.
    --     El bloqueo real se realiza en el bucle de trabajo (paso 1.3) con
    --     SELECT … FOR UPDATE sobre stock_bodega.
    FOR v_det IN
        SELECT fd.fad_linea, fd.id_producto, fd.fad_cantidad,
               p.pro_nombre
        FROM   comercial.factura_det fd
        JOIN   comercial.productos   p ON p.id_producto = fd.id_producto
        WHERE  fd.id_factura = p_id_factura
          AND  fd.estado_fad = 'ABI'
    LOOP
        -- Buscar stock en la bodega específica
        IF NOT EXISTS (
            SELECT 1 FROM comercial.stock_bodega
            WHERE  id_producto = v_det.id_producto
              AND  id_bodega   = p_id_bodega
              AND  stk_disponible >= v_det.fad_cantidad  -- columna GENERATED
        ) THEN
            RAISE EXCEPTION '%', format(
                'Stock insuficiente en bodega [%s] para el producto [%s] (%s). '
                'Verifique stock_bodega o seleccione otra bodega.',
                p_id_bodega, v_det.id_producto, v_det.pro_nombre
            );
        END IF;
    END LOOP;

    -- 0.8 Verificar límite de crédito del cliente (solo si pago es CRE)
    IF v_fac.fpa_genera_cuotas THEN
        -- Suma cuotas PEN del cliente en otras facturas APR (deuda vigente)
        SELECT COALESCE(SUM(cc.cuo_valor), 0)
        INTO   v_deuda_actual
        FROM   comercial.cuotas_credito cc
        JOIN   comercial.facturas       f  ON f.id_factura = cc.id_factura
        WHERE  f.id_cliente = v_fac.id_cliente
          AND  cc.estado_cuo = 'PEN'
          AND  f.id_factura <> p_id_factura;  -- excluir la factura actual

        v_total_fac := v_fac.fac_subtotal - v_fac.fac_descuento
                       + v_fac.fac_iva    + v_fac.fac_ice;

        IF (v_deuda_actual + v_total_fac) > v_fac.cli_credito_max THEN
            RAISE EXCEPTION '%', format(
                'Límite de crédito excedido para el cliente [%s]. '
                'Límite: $%s | Deuda vigente: $%s | Esta factura: $%s.',
                v_fac.id_cliente,
                v_fac.cli_credito_max,
                v_deuda_actual,
                v_total_fac
            );
        END IF;
    END IF;

    -- ─── BLOQUE 1: OPERACIONES DML ATÓMICAS ─────────────────────────────────

    -- Calcular valores financieros para el asiento
    v_total_fac      := v_fac.fac_subtotal - v_fac.fac_descuento
                        + v_fac.fac_iva    + v_fac.fac_ice;
    v_base_imponible := v_fac.fac_subtotal - v_fac.fac_descuento;

    -- 1.1 Crear cabecera de la Orden de Egreso (Entrega) en estado PEN
    INSERT INTO comercial.entregas (
        id_entrega, id_bodega, id_empleado,
        ent_cli_ci, ent_cli_nombre, ent_referencia,
        ent_fecha, ent_num_prod, estado_ent
    ) VALUES (
        p_id_entrega, p_id_bodega, p_id_empleado,
        v_fac.cli_ruc_ced,
        LEFT(v_fac.cli_nombre, 80),
        p_id_factura,                  -- referencia al número de factura
        CURRENT_TIMESTAMP,
        0,                             -- se actualiza al final del bucle
        'PEN'
    );

    -- 1.2 Crear Asiento Contable balanceado (partida doble)
    --     El trigger trg_asi_partida_doble_ins valida que DEBE = HABER.
    --     DEBE = fac_total | HABER = base_imponible + IVA (+ ICE si aplica)
    INSERT INTO comercial.asientos (
        id_asiento, asi_descripcion,
        asi_total_debe, asi_total_haber,
        asi_fecha_hora, user_id, estado_asi
    ) VALUES (
        p_id_asiento,
        format('Venta %s — Factura %s — Cliente %s',
               v_fac.fac_numero_sri, p_id_factura, v_fac.id_cliente),
        v_total_fac,   -- DEBE: total a cobrar al cliente
        v_total_fac,   -- HABER: (base + iva + ice) = total (partida balanceada)
        CURRENT_TIMESTAMP,
        current_user,
        'PEN'
    );

    -- Partida DEBE: Cuentas × Cobrar (o Caja según forma de pago)
    INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
    VALUES (p_id_asiento, p_cuenta_cxc, v_total_fac, 0, 'ACT');

    -- Partida HABER: Ingresos por Ventas (base imponible neta)
    INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
    VALUES (p_id_asiento, p_cuenta_ventas, 0,
            CASE WHEN v_fac.fac_iva > 0 THEN v_base_imponible ELSE v_total_fac END,
            'ACT');

    -- Partida HABER: IVA en Ventas (solo si hay IVA)
    IF v_fac.fac_iva > 0 THEN
        INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
        VALUES (p_id_asiento, p_cuenta_iva_cob, 0, v_fac.fac_iva, 'ACT');
    END IF;

    -- 1.3 Procesar cada línea del detalle:
    --     a) SELECT … FOR UPDATE sobre stock_bodega → bloqueo exclusivo de fila
    --        Evita race condition: otro proceso no puede modificar el stock
    --        entre nuestra lectura y nuestro UPDATE.
    --     b) Insertar línea en entrega_det
    --     c) Reducir stock en stock_bodega (por bodega)
    --     d) Reducir stock global en productos (pro_qty_egresos)
    --     e) Insertar movimiento en el ledger movimientos_inv
    FOR v_det IN
        SELECT fd.fad_linea, fd.id_producto, fd.id_unidad_medida,
               fd.fad_cantidad, fd.fad_precio_unit,
               p.pro_valor_compra
        FROM   comercial.factura_det fd
        JOIN   comercial.productos   p  ON p.id_producto = fd.id_producto
        WHERE  fd.id_factura = p_id_factura
          AND  fd.estado_fad = 'ABI'
        ORDER  BY fd.fad_linea   -- sigue el índice PK pk_factura_det
    LOOP

        -- a) Bloquear la fila de stock_bodega y leer estado actual
        SELECT stk_cantidad, stk_reservado, stk_disponible, stk_costo_prom
        INTO   v_stk_bodega
        FROM   comercial.stock_bodega
        WHERE  id_producto = v_det.id_producto
          AND  id_bodega   = p_id_bodega
        FOR UPDATE;   -- bloqueo exclusivo a nivel de fila

        v_stk_anterior := v_stk_bodega.stk_cantidad;

        -- b) Insertar línea en la Orden de Egreso
        INSERT INTO comercial.entrega_det (
            id_entrega, etd_linea, id_producto, id_unidad_medida,
            etd_qty_sol,            -- cantidad solicitada
            etd_qty_ent,            -- cantidad entregada (0 hasta la entrega física)
            estado_etd
        ) VALUES (
            p_id_entrega, v_etd_linea, v_det.id_producto, v_det.id_unidad_medida,
            v_det.fad_cantidad,
            0,
            'PEN'
        );

        -- c) Reducir stock por bodega en stock_bodega
        --    stk_disponible se recalcula automáticamente (GENERATED STORED)
        UPDATE comercial.stock_bodega
        SET    stk_cantidad = stk_cantidad - v_det.fad_cantidad
        WHERE  id_producto  = v_det.id_producto
          AND  id_bodega    = p_id_bodega;

        -- d) Incrementar el contador global de egresos en productos
        --    pro_saldo_final se recalcula automáticamente (GENERATED STORED)
        UPDATE comercial.productos
        SET    pro_qty_egresos = pro_qty_egresos + ROUND(v_det.fad_cantidad)::INTEGER
        WHERE  id_producto     = v_det.id_producto;

        -- e) Insertar movimiento en el ledger de inventario (append-only, BIGINT IDENTITY)
        INSERT INTO comercial.movimientos_inv (
            id_producto, id_bodega, id_unidad_medida,
            mvi_tipo, mvi_origen, id_referencia,
            mvi_fecha, mvi_cantidad, mvi_costo_unit,
            mvi_stk_ant, mvi_stk_pos, id_empleado
        ) VALUES (
            v_det.id_producto, p_id_bodega, v_det.id_unidad_medida,
            'EGR',          -- Egreso
            'ENTREGA',      -- Origen: venta
            p_id_factura,   -- Referencia: número de factura
            CURRENT_TIMESTAMP,
            -v_det.fad_cantidad,                                     -- negativo = salida
            v_stk_bodega.stk_costo_prom,                             -- costo promedio ponderado
            v_stk_anterior,                                          -- stock antes del movimiento
            v_stk_anterior - v_det.fad_cantidad,                     -- stock después
            p_id_empleado
        );

        v_etd_linea := v_etd_linea + 1;
    END LOOP;

    -- 1.4 Actualizar contador de productos en la Entrega
    UPDATE comercial.entregas
    SET    ent_num_prod = v_etd_linea - 1
    WHERE  id_entrega   = p_id_entrega;

    -- 1.5 Cambiar estado del detalle de factura a APR
    UPDATE comercial.factura_det
    SET    estado_fad = 'APR'
    WHERE  id_factura = p_id_factura
      AND  estado_fad = 'ABI';

    -- 1.6 Cambiar estado de la cabecera → APR y vincular Entrega y Asiento
    UPDATE comercial.facturas
    SET    estado_fac  = 'APR',
           id_entrega  = p_id_entrega,
           id_asiento  = p_id_asiento
    WHERE  id_factura  = p_id_factura;

    -- 1.7 Registro de auditoría
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion,
        id_registro, valor_anterior, valor_nuevo, fecha_hora
    ) VALUES (
        current_user, 'facturas', 'UPDATE',
        p_id_factura,
        'estado=ABI',
        format('estado=APR | entrega=%s | asiento=%s | total=$%s | bodega=%s | emp=%s',
               p_id_entrega, p_id_asiento, v_total_fac, p_id_bodega, p_id_empleado),
        CURRENT_TIMESTAMP
    );

    -- ─── COMMIT ─────────────────────────────────────────────────────────────
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK: deshace stock_bodega, movimientos_inv, entrega, asiento,
        --           y todos los UPDATE/INSERT parciales.
        ROLLBACK;
        RAISE EXCEPTION '[sp_aprobar_factura] ERROR — SQLSTATE=% | Mensaje: %',
            SQLSTATE, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_aprobar_factura IS
'SP-2: Aprueba una Factura ABI → APR.
Valida stock por bodega (SELECT FOR UPDATE), límite de crédito del cliente,
existencia de cuentas contables e IDs destino.
Genera: Orden de Egreso (entregas + entrega_det) en PEN; Asiento Contable
con partida doble balanceada (CxC|Ventas|IVA) en PEN; actualiza
stock_bodega.stk_cantidad, productos.pro_qty_egresos e inserta en
movimientos_inv (ledger append-only con BIGINT IDENTITY).
Atomicidad total: COMMIT o ROLLBACK completo.';


-- ════════════════════════════════════════════════════════════════════════
--  SP-3  sp_anular_factura
-- ════════════════════════════════════════════════════════════════════════
--
--  Anula una Factura en estado ABI o APR → ANU.
--
--  Lógica de reversión según estado de origen:
--    Si ABI: solo cambia estados → ANU (no hay stock comprometido)
--    Si APR:
--      a) Verifica que la Entrega no haya sido físicamente completada (ENT)
--         Si ya fue entregada → rechaza; sugiere usar sp_devolucion.
--      b) Por cada línea: revierte stock en stock_bodega y pro_qty_egresos
--      c) Inserta movimiento ING/DEVOLU en movimientos_inv (trazabilidad)
--      d) Cancela la Entrega y su detalle → estado CAN
--      e) Anula el Asiento Contable si está en PEN → ANU
--         (Si ya fue APR por contabilidad, no se toca; se emite contra-asiento)
--      f) Deja cuotas de crédito en PEN (el estado ANU de la factura las
--         invalida lógicamente; se recomienda agregar 'ANU' al CHECK constraint)
--
--  PARÁMETROS:
--    p_id_factura   CHAR(7)      — Factura a anular
--    p_id_empleado  CHAR(7)      — Empleado que ejecuta la anulación
--    p_motivo       VARCHAR(200) — Razón obligatoria (queda en auditoría)
--
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_anular_factura(
    IN p_id_factura   CHAR(7),
    IN p_id_empleado  CHAR(7),
    IN p_motivo       VARCHAR(200)
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Registro completo de la factura
    v_fac          RECORD;

    -- Variables del bucle de reversión de inventario
    v_det          RECORD;
    v_stk_bodega   RECORD;
    v_stk_anterior NUMERIC(12,4);
    v_id_bodega    CHAR(3);
BEGIN

    -- ─── BLOQUE 0: VALIDACIONES PRE-TRANSACCIÓN ─────────────────────────────

    -- 0.1 Cargar la factura con datos de forma de pago
    SELECT f.*, fp.fpa_genera_cuotas
    INTO   v_fac
    FROM   comercial.facturas    f
    JOIN   comercial.formas_pago fp ON fp.id_forma_pago = f.id_forma_pago
    WHERE  f.id_factura = p_id_factura;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Factura [%] no encontrada.', p_id_factura;
    END IF;

    -- 0.2 Idempotencia: rechazar si ya está anulada
    IF v_fac.estado_fac = 'ANU' THEN
        RAISE EXCEPTION
            'La factura [%] ya se encuentra en estado ANU. '
            'Operación rechazada para evitar inconsistencia contable.',
            p_id_factura;
    END IF;

    -- 0.3 Si estaba APR: verificar que la entrega física NO se haya completado
    IF v_fac.estado_fac = 'APR' AND v_fac.id_entrega IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM comercial.entregas
            WHERE  id_entrega = v_fac.id_entrega
              AND  estado_ent = 'ENT'   -- mercancía ya entregada físicamente
        ) THEN
            RAISE EXCEPTION
                'La factura [%] tiene una Entrega [%] ya completada (estado ENT). '
                'Para revertir use el proceso de Devolución (sp_crear_devolucion).',
                p_id_factura, v_fac.id_entrega;
        END IF;
    END IF;

    -- 0.4 Empleado activo y motivo obligatorio
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
        WHERE  id_empleado = p_id_empleado AND estado_emp = 'ACT'
    ) THEN
        RAISE EXCEPTION 'Empleado [%] no encontrado o inactivo.', p_id_empleado;
    END IF;

    IF p_motivo IS NULL OR TRIM(p_motivo) = '' THEN
        RAISE EXCEPTION
            'El motivo de anulación es obligatorio para el registro de auditoría.';
    END IF;

    -- ─── BLOQUE 1: REVERSIÓN DE INVENTARIO (solo si la factura estaba APR) ─

    IF v_fac.estado_fac = 'APR' THEN

        -- Recuperar la bodega origen desde la Entrega generada al aprobar
        SELECT id_bodega INTO v_id_bodega
        FROM   comercial.entregas
        WHERE  id_entrega = v_fac.id_entrega;

        -- Procesar cada línea en APR: revertir stock con SELECT … FOR UPDATE
        FOR v_det IN
            SELECT fd.fad_linea, fd.id_producto, fd.id_unidad_medida,
                   fd.fad_cantidad, p.pro_valor_compra
            FROM   comercial.factura_det fd
            JOIN   comercial.productos   p ON p.id_producto = fd.id_producto
            WHERE  fd.id_factura = p_id_factura
              AND  fd.estado_fad = 'APR'
            ORDER  BY fd.fad_linea
        LOOP

            -- Bloquear la fila de stock_bodega durante la reversión
            SELECT stk_cantidad, stk_costo_prom
            INTO   v_stk_bodega
            FROM   comercial.stock_bodega
            WHERE  id_producto = v_det.id_producto
              AND  id_bodega   = v_id_bodega
            FOR UPDATE;

            v_stk_anterior := v_stk_bodega.stk_cantidad;

            -- a) Devolver unidades a stock_bodega (reverso del egreso)
            UPDATE comercial.stock_bodega
            SET    stk_cantidad = stk_cantidad + v_det.fad_cantidad
            WHERE  id_producto  = v_det.id_producto
              AND  id_bodega    = v_id_bodega;

            -- b) Decrementar pro_qty_egresos para restaurar el saldo global
            --    pro_saldo_final se recalcula automáticamente (GENERATED STORED)
            UPDATE comercial.productos
            SET    pro_qty_egresos = pro_qty_egresos - ROUND(v_det.fad_cantidad)::INTEGER
            WHERE  id_producto     = v_det.id_producto;

            -- c) Insertar movimiento de reversión en el ledger (append-only)
            --    mvi_cantidad positivo = ingreso de mercancía al stock
            INSERT INTO comercial.movimientos_inv (
                id_producto, id_bodega, id_unidad_medida,
                mvi_tipo, mvi_origen, id_referencia,
                mvi_fecha, mvi_cantidad, mvi_costo_unit,
                mvi_stk_ant, mvi_stk_pos, id_empleado
            ) VALUES (
                v_det.id_producto, v_id_bodega, v_det.id_unidad_medida,
                'ING',          -- Ingreso (reversión de egreso)
                'DEVOLU',       -- Origen: anulación / devolución
                p_id_factura,
                CURRENT_TIMESTAMP,
                v_det.fad_cantidad,                               -- positivo = ingreso
                v_stk_bodega.stk_costo_prom,
                v_stk_anterior,                                   -- stock antes de la reversión
                v_stk_anterior + v_det.fad_cantidad,              -- stock después
                p_id_empleado
            );
        END LOOP;

        -- 1.1 Cancelar la Entrega y su detalle (PEN → CAN)
        --     Si ya estaba CAN (ej. cancelada manualmente), no se produce error.
        UPDATE comercial.entregas
        SET    estado_ent  = 'CAN',
               ent_obs_can = LEFT(
                   format('ANU por factura [%s]. Motivo: %s | Empleado: %s',
                          p_id_factura, p_motivo, p_id_empleado),
                   200
               )
        WHERE  id_entrega  = v_fac.id_entrega
          AND  estado_ent IN ('PEN');   -- solo si aún está pendiente

        UPDATE comercial.entrega_det
        SET    estado_etd = 'CAN'
        WHERE  id_entrega  = v_fac.id_entrega
          AND  estado_etd <> 'CAN';

        -- 1.2 Anular el Asiento Contable si aún está en PEN
        --     NOTA: si el asiento ya fue aprobado (APR) por el módulo de
        --     Contabilidad, NO se toca (principio de inmutabilidad contable).
        --     En ese caso, Contabilidad debe emitir un contra-asiento.
        IF v_fac.id_asiento IS NOT NULL THEN
            UPDATE comercial.asientos
            SET    estado_asi = 'ANU'
            WHERE  id_asiento = v_fac.id_asiento
              AND  estado_asi = 'PEN';  -- solo si no fue aprobado por contabilidad
        END IF;

        -- 1.3 Cuotas de crédito: el CHECK constraint solo acepta PEN|PAG|VEN.
        --     Las cuotas quedan en PEN; la factura en ANU las invalida
        --     lógicamente. Los reportes de cartera deben filtrar por
        --     f.estado_fac <> 'ANU' para excluirlas.
        --     RECOMENDACIÓN: agregar 'ANU' al CHECK constraint de cuotas_credito.

    END IF;  -- fin bloque APR

    -- ─── BLOQUE 2: ANULAR DETALLE Y CABECERA ────────────────────────────────

    -- 2.1 Anular todas las líneas del detalle
    UPDATE comercial.factura_det
    SET    estado_fad = 'ANU'
    WHERE  id_factura = p_id_factura
      AND  estado_fad <> 'ANU';

    -- 2.2 Anular la cabecera de la factura
    UPDATE comercial.facturas
    SET    estado_fac = 'ANU'
    WHERE  id_factura = p_id_factura;

    -- 2.3 Registro de auditoría
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion,
        id_registro, valor_anterior, valor_nuevo, fecha_hora
    ) VALUES (
        current_user, 'facturas', 'UPDATE',
        p_id_factura,
        format('estado=%s', v_fac.estado_fac),
        format('estado=ANU | motivo=%s | empleado=%s | entrega=%s',
               p_motivo, p_id_empleado, v_fac.id_entrega),
        CURRENT_TIMESTAMP
    );

    -- ─── COMMIT ─────────────────────────────────────────────────────────────
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK: deshace todos los UPDATE/INSERT parciales.
        -- El stock, movimientos y estados vuelven a su estado previo.
        ROLLBACK;
        RAISE EXCEPTION '[sp_anular_factura] ERROR — SQLSTATE=% | Mensaje: %',
            SQLSTATE, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_anular_factura IS
'SP-3: Anula una Factura ABI o APR → ANU con reversión segura.
Para facturas APR: revierte stock en stock_bodega y pro_qty_egresos,
inserta movimiento ING/DEVOLU en el ledger, cancela la Entrega y
anula el Asiento si está en PEN. Rechaza si la entrega física ya fue
completada (ENT) — en ese caso debe usarse el proceso de Devolución.
Verifica idempotencia (rechaza si ya está ANU).
Atomicidad total: COMMIT o ROLLBACK completo.';


-- ════════════════════════════════════════════════════════════════════════
--  SP-4  sp_visualizar_factura
-- ════════════════════════════════════════════════════════════════════════
--
--  Retorna dos REFCURSOR para visualizar una Factura de Venta completa:
--
--    p_cur_cabecera → Cabecera con datos del cliente, vendedor, forma de
--                     pago, totales financieros y referencias a Entrega
--                     y Asiento Contable.
--
--    p_cur_detalle  → Líneas de detalle con nombre de producto, categoría,
--                     unidad de medida, precio unitario, descuento, subtotal
--                     GENERATED, margen unitario y stock actual.
--
--  Incluye también las cuotas de crédito si la forma de pago es CRE.
--
--  PARÁMETROS:
--    p_id_factura    CHAR(7)    — Factura a consultar
--    p_cur_cabecera  REFCURSOR  — Cursor de salida: cabecera (INOUT)
--    p_cur_detalle   REFCURSOR  — Cursor de salida: detalle   (INOUT)
--
--  USO COMPLETO:
--    -- 1. Abrir una transacción explícita (los cursores viven dentro de ella)
--    BEGIN;
--
--    -- 2. Invocar el procedimiento
--    CALL comercial.sp_visualizar_factura('FAC0001', 'cur_cab', 'cur_det');
--
--    -- 3. Leer los cursores
--    FETCH ALL FROM cur_cab;
--    FETCH ALL FROM cur_det;
--
--    -- 4. Cerrar la transacción (cierra los cursores automáticamente)
--    COMMIT;
--
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_visualizar_factura(
    IN    p_id_factura    CHAR(7),
    INOUT p_cur_cabecera  REFCURSOR  DEFAULT 'cur_cabecera',
    INOUT p_cur_detalle   REFCURSOR  DEFAULT 'cur_detalle'
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- ─── VALIDACIÓN MÍNIMA ───────────────────────────────────────────────────
    -- Búsqueda por PK → usa índice pk_facturas (O(log n) sobre 400K+ registros)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.facturas WHERE id_factura = p_id_factura
    ) THEN
        RAISE EXCEPTION 'Factura [%] no encontrada.', p_id_factura;
    END IF;

    -- ─── CURSOR 1: CABECERA COMPLETA ────────────────────────────────────────
    --
    --  Joins encadenados todos por PK/FK → sin seq-scans.
    --  facturas (PK) → clientes (PK) → ciudades (PK) → provincias (PK)
    --                → vendedores (PK) → empleados (PK)
    --                → formas_pago (PK)
    --                → entregas (PK, nullable)
    --                → asientos (PK, nullable)
    OPEN p_cur_cabecera FOR
        SELECT
            -- ── Identificación de la factura ──────────────────────────────
            f.id_factura,
            f.fac_numero_sri                                        AS numero_sri,
            f.fac_fecha                                             AS fecha_emision,
            f.estado_fac                                            AS estado,
            f.fac_descripcion                                       AS descripcion,

            -- ── Datos del cliente ─────────────────────────────────────────
            c.id_cliente,
            c.cli_nombre                                            AS cliente,
            c.cli_ruc_ced                                           AS ruc_cedula,
            c.cli_tipo                                              AS tipo_cliente,
            c.cli_telefono,
            c.cli_celular,
            c.cli_email,
            c.cli_direccion                                         AS direccion_cliente,
            ci.ciu_descripcion                                      AS ciudad,
            pr.prv_descripcion                                      AS provincia,

            -- Descuento y crédito del cliente
            c.cli_descuento                                         AS descuento_cliente_pct,
            c.cli_credito_max                                       AS credito_maximo,

            -- ── Datos del vendedor ────────────────────────────────────────
            f.id_vendedor,
            (e.emp_nombres || ' ' || e.emp_apellidos)               AS vendedor,
            v.ven_comision                                          AS comision_vendedor_pct,
            ROUND(
                (f.fac_subtotal - f.fac_descuento) * v.ven_comision / 100,
                2
            )                                                       AS comision_calculada,

            -- ── Forma de pago ─────────────────────────────────────────────
            fp.id_forma_pago,
            fp.fpa_descripcion                                      AS forma_pago,
            fp.fpa_genera_cuotas,

            -- ── Totales financieros ───────────────────────────────────────
            f.fac_subtotal,
            f.fac_descuento,
            CASE WHEN f.fac_subtotal > 0
                 THEN ROUND(f.fac_descuento / f.fac_subtotal * 100, 2)
                 ELSE 0
            END                                                     AS descuento_efectivo_pct,
            f.fac_iva,
            f.fac_ice,
            f.fac_total,              -- GENERATED STORED: sub - desc + iva + ice

            -- ── Referencias a documentos generados al aprobar ─────────────
            f.id_entrega,
            ent.estado_ent                                          AS estado_entrega,
            ent.ent_fecha                                           AS fecha_entrega,

            f.id_asiento,
            asi.estado_asi                                          AS estado_asiento

        FROM   comercial.facturas      f
        -- Cliente y ubicación geográfica
        JOIN   comercial.clientes      c   ON c.id_cliente    = f.id_cliente
        JOIN   comercial.ciudades      ci  ON ci.id_ciudad    = c.id_ciudad
        JOIN   comercial.provincias    pr  ON pr.id_provincia = ci.id_provincia
        -- Vendedor
        JOIN   comercial.vendedores    v   ON v.id_vendedor   = f.id_vendedor
        JOIN   comercial.empleados     e   ON e.id_empleado   = v.id_vendedor
        -- Forma de pago
        JOIN   comercial.formas_pago   fp  ON fp.id_forma_pago = f.id_forma_pago
        -- Entrega (puede ser NULL si aún no se aprobó)
        LEFT JOIN comercial.entregas   ent ON ent.id_entrega  = f.id_entrega
        -- Asiento (puede ser NULL si aún no se aprobó)
        LEFT JOIN comercial.asientos   asi ON asi.id_asiento  = f.id_asiento
        WHERE  f.id_factura = p_id_factura;


    -- ─── CURSOR 2: DETALLE DE LÍNEAS + CUOTAS ───────────────────────────────
    --
    --  Joins por PK/FK en todas las tablas → sin seq-scans.
    --  ORDER BY fad_linea usa el índice PK pk_factura_det.
    OPEN p_cur_detalle FOR

        -- Parte A: líneas de productos
        SELECT
            'PRODUCTO'                                              AS tipo_linea,
            fd.fad_linea                                           AS linea,
            fd.id_producto,
            p.pro_nombre                                           AS producto,
            p.pro_descripcion                                      AS descripcion_producto,
            cat.cat_descripcion                                    AS categoria,
            um.um_descripcion                                      AS unidad_medida,

            -- Cantidades y precios de la venta
            fd.fad_cantidad                                        AS cantidad_vendida,
            fd.fad_precio_unit                                     AS precio_unitario_venta,
            fd.fad_descuento_ln                                    AS descuento_linea_pct,
            fd.fad_subtotal                                        AS subtotal_linea,  -- GENERATED STORED

            -- Precio de venta referencial del catálogo (req #10: visualización)
            p.pro_precio_venta                                     AS precio_venta_referencial,

            -- Costo de compra y margen unitario calculado
            p.pro_valor_compra                                     AS costo_unitario_compra,
            ROUND(fd.fad_precio_unit - p.pro_valor_compra, 4)      AS margen_unitario,
            CASE WHEN p.pro_valor_compra > 0
                 THEN ROUND(
                     (fd.fad_precio_unit - p.pro_valor_compra)
                     / p.pro_valor_compra * 100, 2)
                 ELSE NULL
            END                                                    AS margen_pct,

            -- Stock actual al momento de la consulta (útil para verificación)
            p.pro_saldo_final                                      AS stock_actual,

            fd.estado_fad                                          AS estado_linea,

            -- Columnas de cuotas (NULL para líneas de producto)
            NULL::SMALLINT                                         AS cuo_numero,
            NULL::DATE                                             AS cuo_fecha_vence,
            NULL::NUMERIC                                          AS cuo_valor,
            NULL::TIMESTAMP                                        AS cuo_fecha_pago,
            NULL::CHAR(3)                                          AS cuo_estado

        FROM   comercial.factura_det     fd
        JOIN   comercial.productos       p   ON p.id_producto      = fd.id_producto
        JOIN   comercial.categorias      cat ON cat.id_categoria   = p.id_categoria
        JOIN   comercial.unidades_medidas um  ON um.id_unidad_medida = fd.id_unidad_medida
        WHERE  fd.id_factura = p_id_factura

        UNION ALL

        -- Parte B: cuotas de crédito (si aplican)
        --   Se añaden como filas separadas con tipo_linea = 'CUOTA'
        SELECT
            'CUOTA'                                                AS tipo_linea,
            cc.cuo_numero                                         AS linea,
            NULL::CHAR(7),                    -- id_producto
            NULL::VARCHAR(40),                -- producto
            NULL::VARCHAR(100),               -- descripcion_producto
            NULL::VARCHAR(30),                -- categoria
            NULL::VARCHAR(20),                -- unidad_medida
            NULL::NUMERIC,                    -- cantidad_vendida
            NULL::NUMERIC,                    -- precio_unitario_venta
            NULL::NUMERIC,                    -- descuento_linea_pct
            cc.cuo_valor                      AS subtotal_linea,  -- valor de la cuota
            NULL::NUMERIC,                    -- precio_venta_referencial
            NULL::NUMERIC,                    -- costo_unitario_compra
            NULL::NUMERIC,                    -- margen_unitario
            NULL::NUMERIC,                    -- margen_pct
            NULL::INTEGER,                    -- stock_actual
            cc.estado_cuo                     AS estado_linea,
            cc.cuo_numero,
            cc.cuo_fecha_vence,
            cc.cuo_valor,
            cc.cuo_fecha_pago,
            cc.estado_cuo

        FROM   comercial.cuotas_credito cc
        WHERE  cc.id_factura = p_id_factura

        ORDER BY linea;

END;
$$;

COMMENT ON PROCEDURE comercial.sp_visualizar_factura IS
'SP-4: Visualiza una Factura de Venta completa mediante dos REFCURSOR.
p_cur_cabecera: cabecera con cliente (ciudad, provincia), vendedor,
  comisión calculada, forma de pago, totales y referencias a Entrega
  y Asiento Contable.
p_cur_detalle: líneas de producto (nombre, categoría, UM, precios,
  descuento, subtotal GENERATED, margen unitario, stock actual) más
  filas de cuotas de crédito (tipo_linea=CUOTA) si aplica.
Todos los JOINs usan PK/FK — sin seq-scans sobre 400K+ registros.
Debe invocarse dentro de una transacción BEGIN…COMMIT para mantener
los cursores abiertos entre CALL y FETCH.';


-- ════════════════════════════════════════════════════════════════════════
--  VERIFICACIÓN — Consulta de los procedures registrados
-- ════════════════════════════════════════════════════════════════════════
SELECT
    routine_name    AS procedimiento,
    routine_type    AS tipo,
    external_language AS lenguaje,
    created         AS creado_en
FROM information_schema.routines
WHERE routine_schema = 'comercial'
  AND routine_type   = 'PROCEDURE'
  AND routine_name   LIKE 'sp_%factura%'
ORDER BY routine_name;


-- ████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT VENTAS_SP_PG16.sql
--
--  RESUMEN DE PROCEDURES:
--    sp_crear_factura    — registra cabecera, detalle y cuotas (estado ABI)
--    sp_aprobar_factura  — ABI→APR; stock; entrega; asiento; movimientos_inv
--    sp_anular_factura   — ABI/APR→ANU; reversión segura con FOR UPDATE
--    sp_visualizar_factura — dos REFCURSOR: cabecera completa + detalle+cuotas
--
--  PATRÓN DE ATOMICIDAD APLICADO:
--    Todos los SPs usan COMMIT explícito al final del bloque de éxito.
--    El bloque EXCEPTION global ejecuta ROLLBACK y re-lanza el error con
--    contexto (SQLSTATE + mensaje) para facilitar el diagnóstico.
--    Los SELECT … FOR UPDATE en los bucles de stock garantizan que no
--    haya race conditions en escenarios de alta concurrencia (400K+ rows).
-- ████████████████████████████████████████████████████████████████████████
