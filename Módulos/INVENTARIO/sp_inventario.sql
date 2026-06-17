-- ████████████████████████████████████████████████████████████████████████
-- ██                                                                    ██
-- ██   MÓDULO INVENTARIOS — STORED PROCEDURES (PostgreSQL 16)          ██
-- ██   Sistema de Comercialización de Productos                         ██
-- ██   JW Cóndor | 2025                                                ██
-- ██                                                                    ██
-- ██   PROCEDIMIENTOS:                                                  ██
-- ██     1. sp_crear_ajuste      — Registra un nuevo ajuste ABI        ██
-- ██     2. sp_aprobar_ajuste    — Aprueba ajuste, mueve stock y        ██
-- ██                               genera asiento contable              ██
-- ██     3. sp_anular_ajuste     — Anula un ajuste en estado ABI        ██
-- ██     4. sp_visualizar_ajuste — Devuelve cabecera + detalle via      ██
-- ██                               dos REFCURSORs                       ██
-- ██                                                                    ██
-- ██   ATOMICIDAD:                                                      ██
-- ██     Cada SP abre su propia transacción (BEGIN implícito en PL/     ██
-- ██     pgSQL dentro de PROCEDURE), ejecuta COMMIT al final del        ██
-- ██     camino feliz y ROLLBACK dentro del bloque EXCEPTION,          ██
-- ██     garantizando que ningún estado intermedio quede persistido     ██
-- ██     ante cualquier error de negocio o de motor.                   ██
-- ██                                                                    ██
-- ██   OPTIMIZACIÓN (400 000+ filas):                                  ██
-- ██     · Todas las búsquedas usan PK / índices únicos (id_ajuste,    ██
-- ██       id_producto, id_bodega) — zero seq-scan sobre tablas        ██
-- ██       grandes.                                                     ██
-- ██     · El UPDATE de stock_bodega es row-level por PK compuesta.    ██
-- ██     · El cursor de sp_visualizar_ajuste filtra por PK             ██
-- ██       (id_ajuste) antes de cualquier JOIN.                        ██
-- ██     · Se usa FOR … IN SELECT (set-at-a-time) en lugar de          ██
-- ██       cursores explícitos para el loop de detalle en crear y      ██
-- ██       aprobar.                                                     ██
-- ████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════
-- TIPO COMPUESTO auxiliar para el cursor de visualización
-- (Se crea solo si no existe, es idempotente)
-- ════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'tp_ajuste_cabecera'
          AND n.nspname = 'comercial'
    ) THEN
        CREATE TYPE comercial.tp_ajuste_cabecera AS (
            id_ajuste       CHAR(7),
            id_bodega       CHAR(3),
            bod_nombre      VARCHAR(60),
            id_empleado     CHAR(7),
            emp_nombres     VARCHAR(40),
            emp_apellidos   VARCHAR(40),
            id_aprobador    CHAR(7),
            apr_nombres     VARCHAR(40),
            apr_apellidos   VARCHAR(40),
            aji_motivo      VARCHAR(200),
            aji_fecha       TIMESTAMP,
            aji_fecha_apr   TIMESTAMP,
            aji_num_prod    INTEGER,
            aji_total       NUMERIC(14,2),
            aji_observacion VARCHAR(300),
            estado_aji      CHAR(3),
            id_asiento      CHAR(7)
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'tp_ajuste_detalle'
          AND n.nspname = 'comercial'
    ) THEN
        CREATE TYPE comercial.tp_ajuste_detalle AS (
            ajd_linea        INTEGER,
            id_producto      CHAR(7),
            pro_nombre       VARCHAR(40),
            id_unidad_medida CHAR(3),
            um_descripcion   VARCHAR(20),
            ajd_cantidad     NUMERIC(12,4),
            ajd_costo_unit   NUMERIC(14,4),
            ajd_subtotal     NUMERIC(14,2),
            ajd_qty_ant      NUMERIC(12,4),
            ajd_qty_nva      NUMERIC(12,4),
            estado_ajd       CHAR(3)
        );
    END IF;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 1. sp_crear_ajuste
-- ════════════════════════════════════════════════════════════════════════
-- Parámetros de entrada:
--   p_id_ajuste   CHAR(7)  — Identificador único del ajuste (ej: 'AJI0001')
--   p_id_bodega   CHAR(3)  — Bodega donde se realiza el ajuste
--   p_id_empleado CHAR(7)  — Empleado que genera el ajuste (Auxiliar de Bodega)
--   p_motivo      TEXT     — Descripción del motivo (quiebre, deterioro, etc.)
--   p_observacion TEXT     — Observaciones adicionales (puede ser NULL)
--   p_productos   JSONB    — Array JSON con los productos a ajustar.
--                            Estructura por elemento:
--                            {
--                              "id_producto":      "PRDXXXX",
--                              "id_unidad_medida": "UNI",
--                              "ajd_cantidad":     -6,   -- negativo = reducción
--                              "ajd_costo_unit":   36.50
--                            }
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_crear_ajuste(
    p_id_ajuste   IN CHAR(7),
    p_id_bodega   IN CHAR(3),
    p_id_empleado IN CHAR(7),
    p_motivo      IN VARCHAR(200),
    p_observacion IN VARCHAR(300),
    p_productos   IN JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Cursor para iterar sobre el array JSON de productos
    v_item        JSONB;
    -- Variables de trabajo para cada línea de detalle
    v_linea       INTEGER       := 1;
    v_id_prod     CHAR(7);
    v_id_um       CHAR(3);
    v_cantidad    NUMERIC(12,4);
    v_costo_unit  NUMERIC(14,4);
    v_qty_ant     NUMERIC(12,4);
    v_qty_nva     NUMERIC(12,4);
    -- Acumuladores para el resumen de cabecera
    v_total       NUMERIC(14,2) := 0.00;
    v_num_prod    INTEGER       := 0;
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- VALIDACIONES PREVIAS (no consumen recursos de escritura)
    -- ──────────────────────────────────────────────────────────────────

    -- 1) Evitar duplicado de ID de ajuste (PK lookup — O(log n))
    IF EXISTS (
        SELECT 1 FROM comercial.ajustes_inv
        WHERE id_ajuste = p_id_ajuste
    ) THEN
        RAISE EXCEPTION
            '[sp_crear_ajuste] El ajuste % ya existe en el sistema.', p_id_ajuste;
    END IF;

    -- 2) Validar que la bodega esté activa (PK lookup)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.bodegas
        WHERE id_bodega = p_id_bodega
          AND estado_bod = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_crear_ajuste] La bodega % no existe o está inactiva.', p_id_bodega;
    END IF;

    -- 3) Validar que el empleado esté activo (PK lookup)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
        WHERE id_empleado = p_id_empleado
          AND estado_emp = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_crear_ajuste] El empleado % no existe o está inactivo.', p_id_empleado;
    END IF;

    -- 4) El array de productos no puede estar vacío
    IF p_productos IS NULL OR jsonb_array_length(p_productos) = 0 THEN
        RAISE EXCEPTION
            '[sp_crear_ajuste] Debe incluir al menos un producto en el ajuste.';
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- INSERCIÓN DE CABECERA (estado inicial = ABI)
    -- ──────────────────────────────────────────────────────────────────
    INSERT INTO comercial.ajustes_inv (
        id_ajuste,    id_bodega,    id_empleado,
        aji_motivo,   aji_fecha,    aji_num_prod,
        aji_total,    aji_observacion, estado_aji
    ) VALUES (
        p_id_ajuste,  p_id_bodega,  p_id_empleado,
        p_motivo,     CURRENT_TIMESTAMP, 0,
        0.00,         p_observacion,    'ABI'
    );

    -- ──────────────────────────────────────────────────────────────────
    -- PROCESAMIENTO DE CADA PRODUCTO DEL ARRAY JSON
    -- ──────────────────────────────────────────────────────────────────
    FOR v_item IN
        SELECT * FROM jsonb_array_elements(p_productos)
    LOOP
        -- Extraer campos del JSON
        v_id_prod    := TRIM(v_item->>'id_producto');
        v_id_um      := TRIM(v_item->>'id_unidad_medida');
        v_cantidad   := (v_item->>'ajd_cantidad')::NUMERIC(12,4);
        v_costo_unit := COALESCE((v_item->>'ajd_costo_unit')::NUMERIC(14,4), 0);

        -- Validar producto activo (PK lookup en productos)
        IF NOT EXISTS (
            SELECT 1 FROM comercial.productos
            WHERE id_producto = v_id_prod
              AND estado_prod = 'ACT'
        ) THEN
            RAISE EXCEPTION
                '[sp_crear_ajuste] Producto % no existe o está inactivo.', v_id_prod;
        END IF;

        -- Validar unidad de medida (PK lookup)
        IF NOT EXISTS (
            SELECT 1 FROM comercial.unidades_medidas
            WHERE id_unidad_medida = v_id_um
        ) THEN
            RAISE EXCEPTION
                '[sp_crear_ajuste] Unidad de medida % no existe.', v_id_um;
        END IF;

        -- Obtener stock actual en la bodega (PK compuesta: producto + bodega)
        SELECT COALESCE(stk_cantidad, 0)
          INTO v_qty_ant
          FROM comercial.stock_bodega
         WHERE id_producto = v_id_prod
           AND id_bodega   = p_id_bodega;

        -- Si aún no hay registro de stock se asume 0
        IF NOT FOUND THEN
            v_qty_ant := 0;
        END IF;

        -- Calcular nueva cantidad proyectada
        v_qty_nva := v_qty_ant + v_cantidad;

        -- No permitir stock negativo resultante
        IF v_qty_nva < 0 THEN
            RAISE EXCEPTION
                '[sp_crear_ajuste] El ajuste de % unidades sobre el producto % '
                'dejaría el stock en negativo (actual: %, resultado: %).',
                v_cantidad, v_id_prod, v_qty_ant, v_qty_nva;
        END IF;

        -- Insertar línea de detalle (PK: id_ajuste + ajd_linea)
        INSERT INTO comercial.ajuste_inv_det (
            id_ajuste,     ajd_linea,    id_producto,
            id_unidad_medida, ajd_cantidad, ajd_costo_unit,
            ajd_qty_ant,   ajd_qty_nva,  estado_ajd
        ) VALUES (
            p_id_ajuste,   v_linea,      v_id_prod,
            v_id_um,       v_cantidad,   v_costo_unit,
            v_qty_ant,     v_qty_nva,    'ABI'
        );

        -- Acumular totales de cabecera
        v_total    := v_total    + (ABS(v_cantidad) * v_costo_unit);
        v_num_prod := v_num_prod + 1;
        v_linea    := v_linea    + 1;
    END LOOP;

    -- ──────────────────────────────────────────────────────────────────
    -- ACTUALIZAR TOTALES EN CABECERA (PK lookup — O(log n))
    -- ──────────────────────────────────────────────────────────────────
    UPDATE comercial.ajustes_inv
       SET aji_num_prod = v_num_prod,
           aji_total    = v_total
     WHERE id_ajuste = p_id_ajuste;

    -- ──────────────────────────────────────────────────────────────────
    -- COMMIT — confirma cabecera + detalle como una unidad atómica
    -- ──────────────────────────────────────────────────────────────────
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK automático: ningún dato queda a medio escribir
        ROLLBACK;
        RAISE;  -- Propaga el mensaje de error al llamante
END;
$$;

COMMENT ON PROCEDURE comercial.sp_crear_ajuste IS
'Crea un Ajuste de Inventario en estado ABI con su cabecera y detalle de productos.
 Valida bodega, empleado, existencia y stock suficiente de cada producto.
 Atomicidad: COMMIT al finalizar con éxito; ROLLBACK ante cualquier error.';


-- ════════════════════════════════════════════════════════════════════════
-- 2. sp_aprobar_ajuste
-- ════════════════════════════════════════════════════════════════════════
-- Parámetros de entrada:
--   p_id_ajuste      CHAR(7)  — Ajuste a aprobar (debe estar en ABI)
--   p_id_aprobador   CHAR(7)  — Empleado con rol de Jefe de Bodega/Contralor
--   p_id_asiento     CHAR(7)  — ID del asiento contable a generar
--   p_cta_inventario CHAR(15) — Cuenta contable de Inventarios (activo)
--   p_cta_ajuste     CHAR(15) — Cuenta contable de Pérdida/Ganancia por ajuste
--
-- Efectos:
--   · estado_aji → APR, aji_fecha_apr = CURRENT_TIMESTAMP
--   · estado_ajd → APR en todas las líneas
--   · stock_bodega.stk_cantidad += ajd_cantidad por producto/bodega
--   · productos.pro_qty_ajustes += ajd_cantidad (saldo_final se recalcula)
--   · Crea asiento contable balanceado en PEN
--   · ajustes_inv.id_asiento ← nuevo asiento
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_aprobar_ajuste(
    p_id_ajuste      IN CHAR(7),
    p_id_aprobador   IN CHAR(7),
    p_id_asiento     IN CHAR(7),
    p_cta_inventario IN CHAR(15),
    p_cta_ajuste     IN CHAR(15)
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Registro de cabecera para lectura segura con FOR UPDATE
    v_ajuste        comercial.ajustes_inv%ROWTYPE;
    -- Variables para procesar el detalle
    v_det           RECORD;
    -- Acumuladores por tipo de movimiento para partida doble
    v_total_negativo NUMERIC(14,2) := 0.00;  -- Pérdidas (ajd_cantidad < 0)
    v_total_positivo NUMERIC(14,2) := 0.00;  -- Ganancias (ajd_cantidad > 0)
    v_debe_inv       NUMERIC(14,2);
    v_haber_inv      NUMERIC(14,2);
    v_debe_ajuste    NUMERIC(14,2);
    v_haber_ajuste   NUMERIC(14,2);
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- BLOQUEAR CABECERA con SELECT ... FOR UPDATE
    -- Evita que dos sesiones aprueben el mismo ajuste en paralelo
    -- (PK lookup — O(log n))
    -- ──────────────────────────────────────────────────────────────────
    SELECT * INTO v_ajuste
      FROM comercial.ajustes_inv
     WHERE id_ajuste = p_id_ajuste
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] El ajuste % no existe.', p_id_ajuste;
    END IF;

    -- Solo se puede aprobar un ajuste en estado ABI
    IF v_ajuste.estado_aji <> 'ABI' THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] El ajuste % tiene estado %. Solo se pueden aprobar ajustes en estado ABI.',
            p_id_ajuste, v_ajuste.estado_aji;
    END IF;

    -- Validar que el aprobador exista y esté activo (PK lookup)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
         WHERE id_empleado = p_id_aprobador
           AND estado_emp  = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] El aprobador % no existe o está inactivo.', p_id_aprobador;
    END IF;

    -- Evitar reutilizar un ID de asiento ya existente (PK lookup)
    IF EXISTS (
        SELECT 1 FROM comercial.asientos WHERE id_asiento = p_id_asiento
    ) THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] Ya existe un asiento con id %.', p_id_asiento;
    END IF;

    -- Validar cuentas contables activas (PK lookup)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.cuentas
         WHERE id_cuenta  = p_cta_inventario
           AND estado_cue = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] Cuenta de inventario % no existe o está inactiva.', p_cta_inventario;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM comercial.cuentas
         WHERE id_cuenta  = p_cta_ajuste
           AND estado_cue = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] Cuenta de ajuste % no existe o está inactiva.', p_cta_ajuste;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PROCESAR CADA LÍNEA DE DETALLE
    -- El JOIN usa la PK compuesta (id_ajuste, ajd_linea) para el
    -- cursor y la PK (id_producto, id_bodega) para los UPDATEs
    -- ──────────────────────────────────────────────────────────────────
    FOR v_det IN
        SELECT ajd_linea,
               id_producto,
               ajd_cantidad,
               ajd_costo_unit,
               ajd_subtotal
          FROM comercial.ajuste_inv_det
         WHERE id_ajuste  = p_id_ajuste
           AND estado_ajd = 'ABI'
         ORDER BY ajd_linea          -- orden determinista
    LOOP
        -- 2.1) Actualizar estado de la línea → APR (PK lookup)
        UPDATE comercial.ajuste_inv_det
           SET estado_ajd = 'APR'
         WHERE id_ajuste = p_id_ajuste
           AND ajd_linea = v_det.ajd_linea;

        -- 2.2) Actualizar stock en la bodega (PK compuesta — O(log n))
        --      Si no existe fila de stock, la creamos (UPSERT)
        INSERT INTO comercial.stock_bodega (
            id_producto, id_bodega,
            stk_cantidad, stk_reservado, stk_costo_prom
        ) VALUES (
            v_det.id_producto, v_ajuste.id_bodega,
            GREATEST(0, v_det.ajd_cantidad),  -- no negativo en INSERT nuevo
            0,
            v_det.ajd_costo_unit
        )
        ON CONFLICT (id_producto, id_bodega)
        DO UPDATE SET
            stk_cantidad = comercial.stock_bodega.stk_cantidad + v_det.ajd_cantidad;

        -- 2.3) Actualizar acumulador pro_qty_ajustes en productos (PK lookup)
        UPDATE comercial.productos
           SET pro_qty_ajustes = pro_qty_ajustes + v_det.ajd_cantidad::INTEGER
         WHERE id_producto = v_det.id_producto;

        -- 2.4) Acumular por signo para partida doble
        IF v_det.ajd_cantidad < 0 THEN
            v_total_negativo := v_total_negativo + v_det.ajd_subtotal;
        ELSE
            v_total_positivo := v_total_positivo + v_det.ajd_subtotal;
        END IF;
    END LOOP;

    -- ──────────────────────────────────────────────────────────────────
    -- CONSTRUCCIÓN DEL ASIENTO CONTABLE (Partida Doble)
    --
    -- Regla contable:
    --   Pérdida (ajuste negativo): DEBE Pérdida/Ajuste / HABER Inventario
    --   Ganancia (ajuste positivo): DEBE Inventario / HABER Ajuste/Ganancia
    --
    -- Para satisfacer el trigger fn_validar_partida_doble (DEBE = HABER)
    -- calculamos los totales netos por cuenta.
    -- ──────────────────────────────────────────────────────────────────
    --   Cuenta Inventario:
    --     DEBE  = ganancias (entran al activo)
    --     HABER = pérdidas  (salen del activo)
    v_debe_inv    := v_total_positivo;
    v_haber_inv   := v_total_negativo;

    --   Cuenta Ajuste (contra):
    --     DEBE  = pérdidas  (cargo a gasto/pérdida)
    --     HABER = ganancias (abono a ingreso/ajuste)
    v_debe_ajuste  := v_total_negativo;
    v_haber_ajuste := v_total_positivo;

    -- Verificación interna (no debería fallar si la lógica es correcta)
    IF (v_debe_inv + v_debe_ajuste) <> (v_haber_inv + v_haber_ajuste) THEN
        RAISE EXCEPTION
            '[sp_aprobar_ajuste] Error interno: la partida doble no cuadra '
            '(DEBE=% vs HABER=%).',
            (v_debe_inv + v_debe_ajuste), (v_haber_inv + v_haber_ajuste);
    END IF;

    -- Insertar asiento cabecera (el trigger valida DEBE = HABER)
    INSERT INTO comercial.asientos (
        id_asiento, asi_descripcion,
        asi_total_debe, asi_total_haber,
        asi_fecha_hora, estado_asi
    ) VALUES (
        p_id_asiento,
        'Ajuste de Inventario ' || p_id_ajuste || ' — ' || v_ajuste.aji_motivo,
        v_debe_inv    + v_debe_ajuste,
        v_haber_inv   + v_haber_ajuste,
        CURRENT_TIMESTAMP,
        'PEN'
    );

    -- Insertar partida de Inventarios
    IF v_debe_inv > 0 OR v_haber_inv > 0 THEN
        INSERT INTO comercial.ctaxasi (
            id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa
        ) VALUES (
            p_id_asiento, p_cta_inventario,
            v_debe_inv, v_haber_inv, 'ACT'
        );
    END IF;

    -- Insertar partida de Ajuste/Pérdida
    IF v_debe_ajuste > 0 OR v_haber_ajuste > 0 THEN
        INSERT INTO comercial.ctaxasi (
            id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa
        ) VALUES (
            p_id_asiento, p_cta_ajuste,
            v_debe_ajuste, v_haber_ajuste, 'ACT'
        );
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- ACTUALIZAR CABECERA DEL AJUSTE → APR (PK lookup)
    -- ──────────────────────────────────────────────────────────────────
    UPDATE comercial.ajustes_inv
       SET estado_aji    = 'APR',
           id_aprobador  = p_id_aprobador,
           id_asiento    = p_id_asiento,
           aji_fecha_apr = CURRENT_TIMESTAMP
     WHERE id_ajuste = p_id_ajuste;

    -- ──────────────────────────────────────────────────────────────────
    -- COMMIT — consolida: detalle APR + stock + pro_qty_ajustes +
    --          asiento + cabecera APR como una sola transacción
    -- ──────────────────────────────────────────────────────────────────
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_aprobar_ajuste IS
'Aprueba un Ajuste de Inventario (ABI → APR).
 Efectos atómicos: actualiza stock_bodega, pro_qty_ajustes y genera asiento contable (PEN).
 Usa SELECT FOR UPDATE para evitar aprobaciones concurrentes del mismo ajuste.
 Atomicidad: COMMIT al finalizar con éxito; ROLLBACK ante cualquier error.';


-- ════════════════════════════════════════════════════════════════════════
-- 3. sp_anular_ajuste
-- ════════════════════════════════════════════════════════════════════════
-- Parámetros de entrada:
--   p_id_ajuste  CHAR(7)      — Ajuste a anular (debe estar en ABI)
--   p_id_usuario CHAR(7)      — Empleado que solicita la anulación
--   p_motivo_anu VARCHAR(200) — Motivo de la anulación (se agrega a observaciones)
--
-- Reglas de negocio:
--   · Solo se pueden anular ajustes en estado ABI.
--   · Un ajuste APR no puede ser anulado por este SP (requiere reversión
--     contable, que es un proceso separado para preservar la integridad
--     del libro mayor).
--   · Un ajuste ya ANU no se vuelve a anular.
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_anular_ajuste(
    p_id_ajuste  IN CHAR(7),
    p_id_usuario IN CHAR(7),
    p_motivo_anu IN VARCHAR(200)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado    CHAR(3);
    v_num_lineas INTEGER;
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- BLOQUEAR cabecera para evitar anulación concurrente
    -- ──────────────────────────────────────────────────────────────────
    SELECT estado_aji INTO v_estado
      FROM comercial.ajustes_inv
     WHERE id_ajuste = p_id_ajuste
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            '[sp_anular_ajuste] El ajuste % no existe.', p_id_ajuste;
    END IF;

    -- Validar que el ajuste esté en ABI
    IF v_estado = 'APR' THEN
        RAISE EXCEPTION
            '[sp_anular_ajuste] El ajuste % ya fue APROBADO. '
            'Para revertirlo utilice el proceso de reversión contable.', p_id_ajuste;
    END IF;

    IF v_estado = 'ANU' THEN
        RAISE EXCEPTION
            '[sp_anular_ajuste] El ajuste % ya se encuentra ANULADO.', p_id_ajuste;
    END IF;

    -- Validar usuario activo (PK lookup)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
         WHERE id_empleado = p_id_usuario
           AND estado_emp  = 'ACT'
    ) THEN
        RAISE EXCEPTION
            '[sp_anular_ajuste] El usuario % no existe o está inactivo.', p_id_usuario;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- ANULAR TODAS LAS LÍNEAS DE DETALLE (filtro por FK + índice)
    -- ──────────────────────────────────────────────────────────────────
    UPDATE comercial.ajuste_inv_det
       SET estado_ajd = 'ANU'
     WHERE id_ajuste  = p_id_ajuste
       AND estado_ajd = 'ABI';

    GET DIAGNOSTICS v_num_lineas = ROW_COUNT;

    -- ──────────────────────────────────────────────────────────────────
    -- ANULAR CABECERA — agrega el motivo al campo observaciones
    -- (PK lookup — O(log n))
    -- ──────────────────────────────────────────────────────────────────
    UPDATE comercial.ajustes_inv
       SET estado_aji      = 'ANU',
           aji_observacion = COALESCE(aji_observacion, '') ||
                             ' | ANULACIÓN por ' || p_id_usuario ||
                             ' el ' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') ||
                             ': ' || p_motivo_anu
     WHERE id_ajuste = p_id_ajuste;

    -- ──────────────────────────────────────────────────────────────────
    -- COMMIT — cabecera ANU + detalle ANU en una sola transacción
    -- ──────────────────────────────────────────────────────────────────
    COMMIT;

    RAISE NOTICE
        '[sp_anular_ajuste] Ajuste % anulado correctamente. Líneas afectadas: %.',
        p_id_ajuste, v_num_lineas;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_anular_ajuste IS
'Anula un Ajuste de Inventario en estado ABI (cabecera + todas las líneas → ANU).
 Protege la integridad contable rechazando la anulación de ajustes ya APROBADOS.
 Atomicidad: COMMIT al finalizar con éxito; ROLLBACK ante cualquier error.';


-- ════════════════════════════════════════════════════════════════════════
-- 4. sp_visualizar_ajuste
-- ════════════════════════════════════════════════════════════════════════
-- Devuelve dos REFCURSORs nombrados:
--   ref_cabecera — 1 fila con todos los datos del encabezado del ajuste,
--                  incluyendo nombres de bodega, empleado y aprobador.
--   ref_detalle  — N filas con el detalle de productos, incluyendo nombre
--                  de producto y descripción de unidad de medida.
--
-- Parámetros:
--   p_id_ajuste   IN  CHAR(7)    — Ajuste a visualizar
--   ref_cabecera  OUT REFCURSOR  — Cursor de cabecera (el llamante hace FETCH)
--   ref_detalle   OUT REFCURSOR  — Cursor de detalle  (el llamante hace FETCH)
--
-- Uso desde psql / aplicación:
--   BEGIN;
--   CALL comercial.sp_visualizar_ajuste('AJI0001', 'cur_cab', 'cur_det');
--   FETCH ALL FROM cur_cab;
--   FETCH ALL FROM cur_det;
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_visualizar_ajuste(
    p_id_ajuste  IN  CHAR(7),
    ref_cabecera OUT REFCURSOR,
    ref_detalle  OUT REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- Verificar existencia del ajuste antes de abrir cursores
    -- (PK lookup — O(log n))
    -- ──────────────────────────────────────────────────────────────────
    IF NOT EXISTS (
        SELECT 1 FROM comercial.ajustes_inv
         WHERE id_ajuste = p_id_ajuste
    ) THEN
        RAISE EXCEPTION
            '[sp_visualizar_ajuste] El ajuste % no existe.', p_id_ajuste;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- CURSOR 1: CABECERA
    -- Filtra por PK (id_ajuste) antes de cualquier JOIN;
    -- los JOINs de empleados y bodegas usan sus respectivas PK.
    -- ──────────────────────────────────────────────────────────────────
    OPEN ref_cabecera FOR
        SELECT
            a.id_ajuste,
            a.id_bodega,
            b.bod_nombre,
            a.id_empleado,
            e.emp_nombres                          AS emp_nombres,
            e.emp_apellidos                        AS emp_apellidos,
            a.id_aprobador,
            apr.emp_nombres                        AS apr_nombres,
            apr.emp_apellidos                      AS apr_apellidos,
            a.aji_motivo,
            a.aji_fecha,
            a.aji_fecha_apr,
            a.aji_num_prod,
            a.aji_total,
            a.aji_observacion,
            a.estado_aji,
            a.id_asiento
          FROM comercial.ajustes_inv         a
          JOIN comercial.bodegas             b   ON b.id_bodega   = a.id_bodega
          JOIN comercial.empleados           e   ON e.id_empleado = a.id_empleado
     LEFT JOIN comercial.empleados           apr ON apr.id_empleado = a.id_aprobador
         WHERE a.id_ajuste = p_id_ajuste;

    -- ──────────────────────────────────────────────────────────────────
    -- CURSOR 2: DETALLE
    -- Filtra por FK (id_ajuste) en ajuste_inv_det (cubierto por PK
    -- compuesta id_ajuste + ajd_linea); los JOINs de productos y UM
    -- usan sus PK respectivas.
    -- Ordena por número de línea para presentación consistente.
    -- ──────────────────────────────────────────────────────────────────
    OPEN ref_detalle FOR
        SELECT
            d.ajd_linea,
            d.id_producto,
            p.pro_nombre,
            d.id_unidad_medida,
            u.um_descripcion,
            d.ajd_cantidad,
            d.ajd_costo_unit,
            d.ajd_subtotal,
            d.ajd_qty_ant,
            d.ajd_qty_nva,
            d.estado_ajd
          FROM comercial.ajuste_inv_det    d
          JOIN comercial.productos         p ON p.id_producto      = d.id_producto
          JOIN comercial.unidades_medidas  u ON u.id_unidad_medida = d.id_unidad_medida
         WHERE d.id_ajuste = p_id_ajuste
         ORDER BY d.ajd_linea;

    -- Nota: NO se hace COMMIT aquí porque los REFCURSORs deben mantenerse
    -- abiertos dentro de la transacción del llamante hasta que éste haga
    -- FETCH. El COMMIT lo gestiona el cliente.

EXCEPTION
    WHEN OTHERS THEN
        -- Si hubo error antes de abrir los cursores, devuelve el error limpiamente
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_visualizar_ajuste IS
'Devuelve cabecera y detalle de un Ajuste de Inventario mediante dos REFCURSORs.
 El llamante debe abrir una transacción (BEGIN), llamar al SP y hacer FETCH de
 ambos cursores antes del COMMIT.
 Todos los filtros y JOINs operan sobre índices PK, evitando seq-scans.';


-- ════════════════════════════════════════════════════════════════════════
-- EJEMPLOS DE USO
-- ════════════════════════════════════════════════════════════════════════
/*

-- ─── 1. CREAR un ajuste ──────────────────────────────────────────────
CALL comercial.sp_crear_ajuste(
    'AJI0001',          -- p_id_ajuste
    'B01',              -- p_id_bodega
    'EMP0010',          -- p_id_empleado  (Auxiliar de Bodega)
    'Quiebre de cubierta durante almacenamiento',  -- p_motivo
    'Constatado el 2025-11-12 en bodega central',  -- p_observacion
    '[
        {"id_producto":"PRD0001","id_unidad_medida":"QQ","ajd_cantidad":-6,"ajd_costo_unit":36.50},
        {"id_producto":"PRD0002","id_unidad_medida":"UNI","ajd_cantidad":-10,"ajd_costo_unit":0.85},
        {"id_producto":"PRD0003","id_unidad_medida":"CAJ","ajd_cantidad":-2,"ajd_costo_unit":50.00}
    ]'::JSONB
);

-- ─── 2. APROBAR el ajuste ────────────────────────────────────────────
CALL comercial.sp_aprobar_ajuste(
    'AJI0001',           -- p_id_ajuste
    'EMP0005',           -- p_id_aprobador  (Jefe de Bodega / Contralor)
    'ASI00001',          -- p_id_asiento    (nuevo ID único de asiento)
    '1.1.03.01.01',      -- p_cta_inventario (ej: Inventario de Mercadería)
    '5.1.02.01.01'       -- p_cta_ajuste     (ej: Pérdidas por ajuste de inventario)
);

-- ─── 3. ANULAR un ajuste ─────────────────────────────────────────────
CALL comercial.sp_anular_ajuste(
    'AJI0002',           -- p_id_ajuste
    'EMP0003',           -- p_id_usuario que solicita la anulación
    'Error en el conteo inicial, se reemplaza por AJI0003'  -- p_motivo_anu
);

-- ─── 4. VISUALIZAR un ajuste ─────────────────────────────────────────
-- El sp_visualizar_ajuste REQUIERE una transacción explícita para
-- mantener los cursores abiertos entre el CALL y los FETCH.
BEGIN;
    CALL comercial.sp_visualizar_ajuste('AJI0001', 'cur_cabecera', 'cur_detalle');
    FETCH ALL FROM cur_cabecera;
    FETCH ALL FROM cur_detalle;
COMMIT;

*/

-- ████████████████████████████████████████████████████████████████████████
-- FIN DEL SCRIPT
-- ████████████████████████████████████████████████████████████████████████
