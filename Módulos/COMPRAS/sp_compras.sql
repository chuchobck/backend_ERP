-- ████████████████████████████████████████████████████████████████████████
-- ██                                                                    ██
-- ██   COMERCIAL — STORED PROCEDURES: MÓDULO COMPRAS                   ██
-- ██   Sistema de Comercialización de Productos                         ██
-- ██   JW Cóndor | PostgreSQL 16                                        ██
-- ██                                                                    ██
-- ████████████████████████████████████████████████████████████████████████
--
--  PROCEDIMIENTOS INCLUIDOS:
--    1. sp_crear_compra      — Crea cabecera + detalle de OC (estado ABI)
--    2. sp_aprobar_compra    — ABI → APR; genera Recepción + Asiento Contable
--    3. sp_anular_compra     — ABI → ANU; reversión segura sin efectos contables
--    4. sp_visualizar_compra — Retorna cabecera y detalle vía dos REFCURSOR
--
--  ATOMICIDAD:
--    Cada procedimiento ejecuta su propia unidad atómica de trabajo.
--    Se usa COMMIT explícito al final del bloque feliz; el bloque EXCEPTION
--    ejecuta ROLLBACK + RAISE para que el error ascienda al llamador sin dejar
--    datos inconsistentes. Esta es la semántica correcta en PostgreSQL para
--    PROCEDURE con transaction control (PG 11+).
--
--  PREREQUISITO: SET search_path TO comercial; (o calificar con comercial.)
--
--  EJECUCIÓN:
--    \i COMERCIAL_SP_COMPRAS_PG16.sql
--
-- ████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════
--  TIPO AUXILIAR: fila de detalle para el cursor de sp_visualizar_compra
-- ════════════════════════════════════════════════════════════════════════
-- Se usa en la sección de declaración de sp_visualizar_compra.
-- No se materializa como tabla; sólo dirige el OPEN … FOR SELECT.


-- ════════════════════════════════════════════════════════════════════════
--  1. sp_crear_compra
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Registrar una nueva Orden de Compra (OC) con estado ABI, validando
--    la integridad referencial y de negocio antes de cualquier escritura.
--
--  PARÁMETROS:
--    p_id_compra        CHAR(7)  — ID único de la OC (ej. 'OC00001')
--    p_id_proveedor     CHAR(7)  — FK a proveedores; debe estar ACT
--    p_id_empleado      CHAR(7)  — FK a empleados que genera la OC; debe estar ACT
--    p_id_departamento  CHAR(3)  — FK a departamentos
--    p_fecha_entrega    DATE     — Fecha prometida de entrega (>= fecha actual)
--    p_id_descuento     CHAR(3)  — FK a th_descuentos (NULL si no aplica)
--    p_productos        JSON     — Array de objetos:
--                                  [{"id_producto":"PRD0001",
--                                    "cantidad":10,
--                                    "valor_unitario":25.50}, ...]
--
--  LÓGICA TRANSACCIONAL:
--    Toda la operación (INSERT compras + n INSERT proxoc) se confirma
--    con un COMMIT único. Si cualquier validación o escritura falla, el
--    EXCEPTION ejecuta ROLLBACK completo.
--
--  CÁLCULOS FINANCIEROS:
--    subtotal = Σ(cantidad × valor_unitario) × (1 − %descuento/100)
--    iva      = subtotal × 0.15   (IVA Ecuador 15%)
--    total    = subtotal + iva
--
--  ÍNDICES UTILIZADOS:
--    pk_proveedores (id_proveedor) — lookup O(log n)
--    pk_empleados   (id_empleado)  — lookup O(log n)
--    pk_departamentos              — lookup O(log n)
--    pk_compras     (id_compra)    — check duplicado O(log n)
--    pk_productos   (id_producto)  — lookup por cada línea O(log n)
--    pk_proveedor_producto (id_proveedor, id_producto) — validación relación

DROP PROCEDURE IF EXISTS comercial.sp_aprobar_compra(CHAR, CHAR, CHAR, CHAR, CHAR, CHAR);

CREATE OR REPLACE PROCEDURE comercial.sp_aprobar_compra(
    IN p_id_compra       CHAR(7),
    IN p_id_aprobador    CHAR(7),
    IN p_id_bodega       CHAR(3),
    IN p_cta_inventario  CHAR(15),
    IN p_cta_iva_compras CHAR(15),
    IN p_cta_proveedores CHAR(15)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_oc   CHAR(3);
    v_subtotal    NUMERIC(12,2);
    v_iva         NUMERIC(12,2);
    v_total       NUMERIC(12,2);
    v_estado_emp  CHAR(3);
    v_estado_bod  CHAR(3);
    v_id_recibo   CHAR(7);
    v_id_asiento  CHAR(7);
    v_id_producto CHAR(7);
    v_cantidad    INTEGER;
    v_valor_unit  NUMERIC(10,2);
    v_num_prods   INTEGER := 0;
    v_stk_qty     NUMERIC(12,4);
    v_stk_costo   NUMERIC(14,6);
    v_nuevo_costo NUMERIC(14,6);
    cur_detalle CURSOR FOR
        SELECT id_producto, pxo_cantidad, pxo_valor
          FROM comercial.proxoc
         WHERE id_compra = p_id_compra AND estado_pxoc = 'ABI';
    v_max_rec INTEGER;
    v_max_asi INTEGER;
BEGIN
    -- Generar id_recibo extrayendo solo los números después de REC
    SELECT COALESCE(MAX(SUBSTRING(id_recibo FROM '^REC([0-9]{4})$')::INTEGER), 0)
    INTO v_max_rec
    FROM comercial.recepciones
    WHERE id_recibo ~ '^REC[0-9]{4}$';
    v_id_recibo := 'REC' || LPAD((v_max_rec + 1)::TEXT, 4, '0');

    -- Generar id_asiento extrayendo solo los números después de ASI
    SELECT COALESCE(MAX(SUBSTRING(id_asiento FROM '^ASI([0-9]{4})$')::INTEGER), 0)
    INTO v_max_asi
    FROM comercial.asientos
    WHERE id_asiento ~ '^ASI[0-9]{4}$';
    v_id_asiento := 'ASI' || LPAD((v_max_asi + 1)::TEXT, 4, '0');

    -- Validaciones (igual que antes)
    SELECT estado_oc, oc_subtotal, oc_iva, oc_total
      INTO v_estado_oc, v_subtotal, v_iva, v_total
      FROM comercial.compras WHERE id_compra = p_id_compra;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La OC % no existe.', p_id_compra;
    END IF;
    IF v_estado_oc <> 'ABI' THEN
        RAISE EXCEPTION 'OC % estado %. Solo ABI es aprobable.', p_id_compra, v_estado_oc;
    END IF;

    SELECT estado_emp INTO v_estado_emp FROM comercial.empleados WHERE id_empleado = p_id_aprobador;
    IF NOT FOUND OR v_estado_emp <> 'ACT' THEN
        RAISE EXCEPTION 'Aprobador % no existe o inactivo.', p_id_aprobador;
    END IF;

    SELECT estado_bod INTO v_estado_bod FROM comercial.bodegas WHERE id_bodega = p_id_bodega;
    IF NOT FOUND OR v_estado_bod <> 'ACT' THEN
        RAISE EXCEPTION 'Bodega % no existe o inactiva.', p_id_bodega;
    END IF;

    PERFORM FROM comercial.cuentas WHERE id_cuenta = p_cta_inventario AND estado_cue = 'ACT';
    IF NOT FOUND THEN RAISE EXCEPTION 'Cuenta inventario % inválida.', p_cta_inventario; END IF;
    PERFORM FROM comercial.cuentas WHERE id_cuenta = p_cta_iva_compras AND estado_cue = 'ACT';
    IF NOT FOUND THEN RAISE EXCEPTION 'Cuenta IVA % inválida.', p_cta_iva_compras; END IF;
    PERFORM FROM comercial.cuentas WHERE id_cuenta = p_cta_proveedores AND estado_cue = 'ACT';
    IF NOT FOUND THEN RAISE EXCEPTION 'Cuenta proveedores % inválida.', p_cta_proveedores; END IF;

    -- Actualizar estados
    UPDATE comercial.compras SET estado_oc = 'APR' WHERE id_compra = p_id_compra;
    UPDATE comercial.proxoc SET estado_pxoc = 'APR' WHERE id_compra = p_id_compra AND estado_pxoc = 'ABI';

    -- Recepción cabecera
    SELECT COUNT(*) INTO v_num_prods FROM comercial.proxoc WHERE id_compra = p_id_compra;
    INSERT INTO comercial.recepciones (id_recibo, id_compra, rec_descripcion, rec_num_productos, estado_rec)
    VALUES (v_id_recibo, p_id_compra, 'Orden de ingreso OC '||p_id_compra, v_num_prods, 'PEN');

    -- Detalle
    OPEN cur_detalle;
    LOOP
        FETCH cur_detalle INTO v_id_producto, v_cantidad, v_valor_unit;
        EXIT WHEN NOT FOUND;

        INSERT INTO comercial.proxrec (id_recibo, id_producto, prx_cantidad, prx_qty_recibida, estado_pxrec)
        VALUES (v_id_recibo, v_id_producto, v_cantidad, 0, 'PEN');

        SELECT stk_cantidad, stk_costo_prom INTO v_stk_qty, v_stk_costo
          FROM comercial.stock_bodega
         WHERE id_producto = v_id_producto AND id_bodega = p_id_bodega;
        IF FOUND THEN
            v_nuevo_costo := ROUND((v_stk_qty * v_stk_costo + v_cantidad * v_valor_unit) / (v_stk_qty + v_cantidad), 6);
            UPDATE comercial.stock_bodega
               SET stk_cantidad = stk_cantidad + v_cantidad,
                   stk_costo_prom = v_nuevo_costo
             WHERE id_producto = v_id_producto AND id_bodega = p_id_bodega;
        ELSE
            INSERT INTO comercial.stock_bodega (id_producto, id_bodega, stk_cantidad, stk_reservado, stk_costo_prom)
            VALUES (v_id_producto, p_id_bodega, v_cantidad, 0, v_valor_unit);
        END IF;

        UPDATE comercial.productos SET pro_qty_ingresos = pro_qty_ingresos + v_cantidad
         WHERE id_producto = v_id_producto;
    END LOOP;
    CLOSE cur_detalle;

    -- Asiento contable
    INSERT INTO comercial.asientos (id_asiento, asi_descripcion, asi_total_debe, asi_total_haber, estado_asi)
    VALUES (v_id_asiento, 'Compra OC '||p_id_compra||' aprobada por '||p_id_aprobador, v_total, v_total, 'PEN');

    INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
    VALUES (v_id_asiento, p_cta_inventario, v_subtotal, 0.00, 'ACT');
    INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
    VALUES (v_id_asiento, p_cta_iva_compras, v_iva, 0.00, 'ACT');
    INSERT INTO comercial.ctaxasi (id_asiento, id_cuenta, cxa_debe, cxa_haber, estado_cxa)
    VALUES (v_id_asiento, p_cta_proveedores, 0.00, v_total, 'ACT');

    COMMIT;
    RAISE NOTICE 'OC % APROBADA — Recibo: % | Asiento: %', p_id_compra, v_id_recibo, v_id_asiento;
END;
$$;

-- ════════════════════════════════════════════════════════════════════════
--  2. sp_aprobar_compra
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Transicionar una OC de ABI → APR y generar los documentos derivados:
--      a) Recepción de bodega (recepciones + proxrec) con estado PEN
--      b) Asiento contable (asientos + ctaxasi) con estado PEN
--      c) Actualización de stock: pro_qty_ingresos en productos y
--         stk_cantidad en stock_bodega (método CPP)
--
--  PARÁMETROS:
--    p_id_compra        CHAR(7)  — OC a aprobar; debe existir en estado ABI
--    p_id_aprobador     CHAR(7)  — Empleado que aprueba (rol Jefe de Compras)
--    p_id_recibo        CHAR(7)  — ID único para la nueva recepción de bodega
--    p_id_asiento       CHAR(7)  — ID único para el nuevo asiento contable
--    p_id_bodega        CHAR(3)  — Bodega destino del ingreso
--    p_cta_inventario   CHAR(15) — Cuenta contable de Inventarios (DEBE)
--    p_cta_iva_compras  CHAR(15) — Cuenta IVA en Compras (DEBE)
--    p_cta_proveedores  CHAR(15) — Cuenta Proveedores / CxP (HABER)
--
--  NOTA CUENTAS CONTABLES:
--    Los IDs de cuenta deben existir en comercial.cuentas con estado ACT.
--    Ejemplo orientativo del plan de cuentas ecuatoriano:
--      p_cta_inventario  → '1.1.03.01.001'  (Inventario de mercadería)
--      p_cta_iva_compras → '1.1.04.01.001'  (IVA crédito tributario)
--      p_cta_proveedores → '2.1.01.01.001'  (Proveedores locales)
--
--  PARTIDA DOBLE (exigida por trigger trg_asi_partida_doble_ins):
--    DEBE:  oc_subtotal (Inventario) + oc_iva (IVA Compras)  = oc_total
--    HABER: oc_total    (Proveedores)                        = oc_total
--    ∴  DEBE == HABER  ✓
--
--  ACTUALIZACIÓN DE STOCK (método CPP — Costo Promedio Ponderado):
--    nuevo_costo_prom = (stk_cantidad × stk_costo_prom + pxo_cantidad × pxo_valor)
--                       / (stk_cantidad + pxo_cantidad)
--
--  ÍNDICES UTILIZADOS:
--    pk_compras       (id_compra)
--    pk_proxoc        (id_compra, id_producto) — scan de detalle
--    pk_recepciones   (id_recibo)
--    pk_asientos      (id_asiento)
--    pk_stock_bodega  (id_producto, id_bodega) — UPSERT de stock
--    pk_productos     (id_producto) — UPDATE qty_ingresos

DROP PROCEDURE IF EXISTS comercial.sp_aprobar_compra(
    CHAR, CHAR, CHAR, CHAR, CHAR, CHAR, CHAR, CHAR
);

CREATE OR REPLACE PROCEDURE comercial.sp_aprobar_compra(
    IN p_id_compra       CHAR(7),
    IN p_id_aprobador    CHAR(7),
    IN p_id_recibo       CHAR(7),
    IN p_id_asiento      CHAR(7),
    IN p_id_bodega       CHAR(3),
    IN p_cta_inventario  CHAR(15),
    IN p_cta_iva_compras CHAR(15),
    IN p_cta_proveedores CHAR(15)
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ── Variables de cabecera de compra ─────────────────────────────────
    v_estado_oc    CHAR(3);
    v_subtotal     NUMERIC(12,2);
    v_iva          NUMERIC(12,2);
    v_total        NUMERIC(12,2);
    v_estado_emp   CHAR(3);
    v_estado_bod   CHAR(3);

    -- ── Variables para iterar el detalle de la OC ───────────────────────
    v_id_producto  CHAR(7);
    v_cantidad     INTEGER;
    v_valor_unit   NUMERIC(10,2);
    v_num_prods    INTEGER := 0;

    -- ── Variables para CPP (costo promedio ponderado) ───────────────────
    v_stk_qty      NUMERIC(12,4);
    v_stk_costo    NUMERIC(14,6);
    v_nuevo_costo  NUMERIC(14,6);

    -- ── Cursor para recorrer detalle de OC ──────────────────────────────
    cur_detalle CURSOR FOR
        SELECT id_producto, pxo_cantidad, pxo_valor
          FROM comercial.proxoc
         WHERE id_compra = p_id_compra
           AND estado_pxoc = 'ABI';
BEGIN
    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 1: VALIDACIONES PRE-APROBACIÓN
    -- ────────────────────────────────────────────────────────────────────

    -- [V-01] OC existe y está en estado ABI (usa pk_compras → O(log n))
    SELECT estado_oc, oc_subtotal, oc_iva, oc_total
      INTO v_estado_oc, v_subtotal, v_iva, v_total
      FROM comercial.compras
     WHERE id_compra = p_id_compra;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] La OC % no existe.', p_id_compra;
    END IF;
    IF v_estado_oc <> 'ABI' THEN
        RAISE EXCEPTION '[sp_aprobar_compra] La OC % tiene estado %. Solo se pueden aprobar OC en estado ABI.',
            p_id_compra, v_estado_oc;
    END IF;

    -- [V-02] Aprobador existe y está ACTIVO
    SELECT estado_emp INTO v_estado_emp
      FROM comercial.empleados
     WHERE id_empleado = p_id_aprobador;

    IF NOT FOUND OR v_estado_emp <> 'ACT' THEN
        RAISE EXCEPTION '[sp_aprobar_compra] APROBADOR % no existe o está INACTIVO.', p_id_aprobador;
    END IF;

    -- [V-03] Bodega existe y está ACTIVA
    SELECT estado_bod INTO v_estado_bod
      FROM comercial.bodegas
     WHERE id_bodega = p_id_bodega;

    IF NOT FOUND OR v_estado_bod <> 'ACT' THEN
        RAISE EXCEPTION '[sp_aprobar_compra] BODEGA % no existe o está INACTIVA.', p_id_bodega;
    END IF;

    -- [V-04] ID de recibo no duplicado
    PERFORM 1 FROM comercial.recepciones WHERE id_recibo = p_id_recibo;
    IF FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] Ya existe una RECEPCIÓN con ID %.', p_id_recibo;
    END IF;

    -- [V-05] ID de asiento no duplicado
    PERFORM 1 FROM comercial.asientos WHERE id_asiento = p_id_asiento;
    IF FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] Ya existe un ASIENTO con ID %.', p_id_asiento;
    END IF;

    -- [V-06] Cuentas contables existen y están ACTIVAS
    PERFORM 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_inventario  AND estado_cue = 'ACT';
    IF NOT FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] CUENTA INVENTARIO % no existe o está INACTIVA.', p_cta_inventario;
    END IF;

    PERFORM 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_iva_compras AND estado_cue = 'ACT';
    IF NOT FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] CUENTA IVA COMPRAS % no existe o está INACTIVA.', p_cta_iva_compras;
    END IF;

    PERFORM 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_proveedores AND estado_cue = 'ACT';
    IF NOT FOUND THEN
        RAISE EXCEPTION '[sp_aprobar_compra] CUENTA PROVEEDORES % no existe o está INACTIVA.', p_cta_proveedores;
    END IF;

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 2: ACTUALIZAR ESTADO DE LA OC Y SU DETALLE → APR
    -- ────────────────────────────────────────────────────────────────────

    -- Actualizar cabecera (usa pk_compras → UPDATE puntual, sin full scan)
    UPDATE comercial.compras
       SET estado_oc = 'APR'
     WHERE id_compra = p_id_compra;

    -- Actualizar todas las líneas de detalle en un solo DML
    -- (usa fk_pxoc_compra que debería estar indexado → eficiente)
    UPDATE comercial.proxoc
       SET estado_pxoc = 'APR'
     WHERE id_compra   = p_id_compra
       AND estado_pxoc = 'ABI';

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 3: GENERAR ORDEN DE INGRESO A BODEGA (recepciones + proxrec)
    -- ────────────────────────────────────────────────────────────────────

    -- Contar productos para rec_num_productos
    SELECT COUNT(*) INTO v_num_prods
      FROM comercial.proxoc
     WHERE id_compra = p_id_compra;

    -- Cabecera de recepción con estado PEN (Pendiente de recibir)
    INSERT INTO comercial.recepciones (
        id_recibo,
        id_compra,
        rec_descripcion,
        rec_num_productos,
        estado_rec
    ) VALUES (
        p_id_recibo,
        p_id_compra,
        'Orden de ingreso generada al aprobar OC ' || p_id_compra,
        v_num_prods,
        'PEN'
    );

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 4: ITERAR DETALLE — proxrec + stock_bodega + pro_qty_ingresos
    --  Se usa un CURSOR explícito para controlar fila por fila y aplicar
    --  el Costo Promedio Ponderado (CPP) por producto.
    -- ────────────────────────────────────────────────────────────────────
    OPEN cur_detalle;
    LOOP
        FETCH cur_detalle INTO v_id_producto, v_cantidad, v_valor_unit;
        EXIT WHEN NOT FOUND;

        -- [a] Insertar línea en proxrec (Pendiente de recibir en bodega)
        INSERT INTO comercial.proxrec (
            id_recibo,
            id_producto,
            prx_cantidad,
            prx_qty_recibida,
            estado_pxrec
        ) VALUES (
            p_id_recibo,
            v_id_producto,
            v_cantidad,
            0,        -- aún no se ha recibido físicamente
            'PEN'
        );

        -- [b] UPSERT stock_bodega con Costo Promedio Ponderado (CPP)
        --     Si ya existe registro (producto, bodega) → UPDATE con CPP
        --     Si no existe → INSERT como saldo nuevo
        SELECT stk_cantidad, stk_costo_prom
          INTO v_stk_qty, v_stk_costo
          FROM comercial.stock_bodega
         WHERE id_producto = v_id_producto
           AND id_bodega   = p_id_bodega;

        IF FOUND THEN
            -- Calcular nuevo costo promedio ponderado
            -- CPP = (Qty_existente × Costo_existente + Qty_nueva × Costo_nuevo)
            --       / (Qty_existente + Qty_nueva)
            IF (v_stk_qty + v_cantidad) > 0 THEN
                v_nuevo_costo := ROUND(
                    (v_stk_qty * v_stk_costo + v_cantidad * v_valor_unit)
                    / (v_stk_qty + v_cantidad),
                    6
                );
            ELSE
                v_nuevo_costo := v_valor_unit;
            END IF;

            UPDATE comercial.stock_bodega
               SET stk_cantidad   = stk_cantidad + v_cantidad,
                   stk_costo_prom = v_nuevo_costo
                   -- stk_ultima_act es actualizado automáticamente por trg_stk_update_timestamp
             WHERE id_producto = v_id_producto
               AND id_bodega   = p_id_bodega;
        ELSE
            -- Primera vez que este producto entra en esta bodega
            INSERT INTO comercial.stock_bodega (
                id_producto,
                id_bodega,
                stk_cantidad,
                stk_reservado,
                stk_costo_prom
            ) VALUES (
                v_id_producto,
                p_id_bodega,
                v_cantidad,
                0,
                v_valor_unit
            );
        END IF;

        -- [c] Actualizar contador de ingresos en la tabla productos
        --     (usa pk_productos → UPDATE puntual O(log n))
        UPDATE comercial.productos
           SET pro_qty_ingresos = pro_qty_ingresos + v_cantidad
         WHERE id_producto = v_id_producto;

    END LOOP;
    CLOSE cur_detalle;

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 5: GENERAR ASIENTO CONTABLE (asientos + ctaxasi)
    --
    --  Partida doble de una compra a crédito:
    --    DEBE:  Inventario     = oc_subtotal  (aumento del activo inventario)
    --    DEBE:  IVA Compras    = oc_iva       (crédito tributario)
    --    HABER: Proveedores    = oc_total     (pasivo: deuda con proveedor)
    --
    --  El trigger trg_asi_partida_doble_ins valida DEBE == HABER en INSERT.
    --  Como oc_subtotal + oc_iva = oc_total, la partida siempre cuadra.
    -- ────────────────────────────────────────────────────────────────────

    -- Cabecera del asiento (estado PEN — pendiente de confirmación contable)
    INSERT INTO comercial.asientos (
        id_asiento,
        asi_descripcion,
        asi_total_debe,
        asi_total_haber,
        estado_asi
    ) VALUES (
        p_id_asiento,
        'Compra OC ' || p_id_compra || ' aprobada por ' || p_id_aprobador,
        v_total,    -- DEBE  = subtotal + iva = total
        v_total,    -- HABER = total (proveedores)
        'PEN'
    );
    -- NOTA: El trigger trg_asi_partida_doble_ins verifica DEBE == HABER antes del INSERT.
    --       Si hubiera error de redondeo, el trigger lo detecta y lanza EXCEPTION.

    -- Partida 1 — Inventario (DEBE: valor de las mercancías sin IVA)
    INSERT INTO comercial.ctaxasi (
        id_asiento,
        id_cuenta,
        cxa_debe,
        cxa_haber,
        estado_cxa
    ) VALUES (
        p_id_asiento,
        p_cta_inventario,
        v_subtotal,
        0.00,
        'ACT'
    );

    -- Partida 2 — IVA Crédito Tributario (DEBE: IVA pagado = crédito fiscal)
    INSERT INTO comercial.ctaxasi (
        id_asiento,
        id_cuenta,
        cxa_debe,
        cxa_haber,
        estado_cxa
    ) VALUES (
        p_id_asiento,
        p_cta_iva_compras,
        v_iva,
        0.00,
        'ACT'
    );

    -- Partida 3 — Proveedores / CxP (HABER: pasivo generado)
    INSERT INTO comercial.ctaxasi (
        id_asiento,
        id_cuenta,
        cxa_debe,
        cxa_haber,
        estado_cxa
    ) VALUES (
        p_id_asiento,
        p_cta_proveedores,
        0.00,
        v_total,
        'ACT'
    );

    -- ────────────────────────────────────────────────────────────────────
    --  COMMIT: confirma todo el flujo APR como una unidad atómica
    -- ────────────────────────────────────────────────────────────────────
    COMMIT;

    RAISE NOTICE '[sp_aprobar_compra] OC % APROBADA. Recibo: % | Asiento: % | Stock bodega % actualizado.',
        p_id_compra, p_id_recibo, p_id_asiento, p_id_bodega;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE EXCEPTION '[sp_aprobar_compra] FALLO — transacción revertida. Detalle: %', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_aprobar_compra(CHAR,CHAR,CHAR,CHAR,CHAR,CHAR,CHAR,CHAR) IS
'Aprueba una OC ABI → APR. Genera Recepción de bodega (PEN) y Asiento contable (PEN).
 Actualiza stock_bodega con CPP y pro_qty_ingresos. Compatible con trigger partida doble.
 ROLLBACK automático ante cualquier fallo en la cadena de operaciones.';


-- ════════════════════════════════════════════════════════════════════════
--  3. sp_anular_compra
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Anular una Orden de Compra que se encuentre en estado ABI.
--    Una OC APR NO puede anularse directamente desde este procedimiento
--    porque ya generó documentos derivados (recepciones + asientos); esa
--    operación requeriría un procedimiento de reversión contable dedicado.
--
--  PARÁMETROS:
--    p_id_compra     CHAR(7)  — ID de la OC a anular
--    p_id_empleado   CHAR(7)  — Empleado que solicita la anulación
--    p_motivo        VARCHAR  — Justificación de la anulación (para auditoría)
--
--  GARANTÍAS:
--    • Solo procesa OC en estado ABI (guard clause estricto)
--    • Actualiza cabecera y TODOS los renglones de proxoc en un solo DML
--    • Sin efectos en stock ni en contabilidad (OC ABI no ha movido inventario)
--    • Inserta registro en auditoria_sistema para trazabilidad
--
--  ÍNDICES UTILIZADOS:
--    pk_compras  (id_compra)               — lookup O(log n)
--    pk_proxoc   (id_compra, id_producto)  — UPDATE por id_compra (rango filtrado)

DROP PROCEDURE IF EXISTS comercial.sp_anular_compra(CHAR, CHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE comercial.sp_anular_compra(
    IN p_id_compra   CHAR(7),
    IN p_id_empleado CHAR(7),
    IN p_motivo      VARCHAR(200) DEFAULT 'Sin motivo especificado'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_oc   CHAR(3);
    v_estado_emp  CHAR(3);
    v_lineas_anu  INTEGER;
BEGIN
    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 1: VALIDACIONES PREVIAS A LA ANULACIÓN
    -- ────────────────────────────────────────────────────────────────────

    -- [V-01] OC existe y su estado actual es recuperable
    SELECT estado_oc INTO v_estado_oc
      FROM comercial.compras
     WHERE id_compra = p_id_compra;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[sp_anular_compra] La OC % no existe.', p_id_compra;
    END IF;

    -- [V-02] Guard clause: solo ABI puede anularse por este procedimiento
    CASE v_estado_oc
        WHEN 'ANU' THEN
            RAISE EXCEPTION '[sp_anular_compra] La OC % ya está ANULADA. Operación idempotente rechazada.', p_id_compra;
        WHEN 'APR' THEN
            RAISE EXCEPTION
                '[sp_anular_compra] La OC % está APROBADA (APR). '
                'Ya generó documentos contables y de bodega. '
                'Ejecute el procedimiento de reversión contable correspondiente.',
                p_id_compra;
        WHEN 'ABI' THEN
            NULL; -- Estado válido para anulación, continuar
        ELSE
            RAISE EXCEPTION '[sp_anular_compra] Estado desconocido (%) en OC %.', v_estado_oc, p_id_compra;
    END CASE;

    -- [V-03] Empleado solicitante existe y está ACTIVO
    SELECT estado_emp INTO v_estado_emp
      FROM comercial.empleados
     WHERE id_empleado = p_id_empleado;

    IF NOT FOUND OR v_estado_emp <> 'ACT' THEN
        RAISE EXCEPTION '[sp_anular_compra] EMPLEADO % no existe o está INACTIVO.', p_id_empleado;
    END IF;

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 2: ANULACIÓN — cabecera y detalle en dos DML eficientes
    -- ────────────────────────────────────────────────────────────────────

    -- Anular cabecera (UPDATE por PK → O(log n), sin full scan)
    UPDATE comercial.compras
       SET estado_oc = 'ANU'
     WHERE id_compra = p_id_compra;

    -- Anular todas las líneas de proxoc en un único UPDATE
    -- (filtro por id_compra — columna de FK, idealmente indexada)
    UPDATE comercial.proxoc
       SET estado_pxoc = 'ANU'
     WHERE id_compra = p_id_compra;

    GET DIAGNOSTICS v_lineas_anu = ROW_COUNT;

    -- ────────────────────────────────────────────────────────────────────
    --  BLOQUE 3: REGISTRO DE AUDITORÍA
    --  Inserta en auditoria_sistema para trazabilidad de la anulación.
    --  Se usa CURRENT_USER (sesión DB) como usuario_db.
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO comercial.auditoria_sistema (
        usuario_db,
        tabla_afectada,
        operacion,
        id_registro,
        valor_anterior,
        valor_nuevo
    ) VALUES (
        CURRENT_USER,
        'compras',
        'UPDATE',
        p_id_compra,
        'estado_oc=ABI',
        'estado_oc=ANU | motivo: ' || p_motivo || ' | empleado: ' || p_id_empleado
    );

    -- ────────────────────────────────────────────────────────────────────
    --  COMMIT: anulación de cabecera + detalle + auditoría en una sola TX
    -- ────────────────────────────────────────────────────────────────────
    COMMIT;

    RAISE NOTICE '[sp_anular_compra] OC % ANULADA. Líneas de detalle anuladas: %. Motivo: %',
        p_id_compra, v_lineas_anu, p_motivo;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE EXCEPTION '[sp_anular_compra] FALLO — transacción revertida. Detalle: %', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_anular_compra(CHAR, CHAR, VARCHAR) IS
'Anula una OC en estado ABI → ANU (cabecera + detalle en una TX atómica).
 Rechaza explícitamente OC APR y OC ya anuladas. Sin efecto en stock ni contabilidad.
 Registra la operación en auditoria_sistema. ROLLBACK automático ante cualquier fallo.';


-- ════════════════════════════════════════════════════════════════════════
--  4. sp_visualizar_compra
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Retornar la información completa de una OC (cabecera + detalle)
--    mediante dos REFCURSOR independientes, permitiendo al cliente
--    iterar ambos conjuntos de resultados en una sola llamada.
--
--  PARÁMETROS:
--    p_id_compra    CHAR(7)     [IN]     — OC a consultar
--    cur_cabecera   REFCURSOR   [INOUT]  — Cursor con datos de cabecera
--    cur_detalle    REFCURSOR   [INOUT]  — Cursor con líneas de detalle
--
--  CABECERA devuelve:
--    id_compra, prv_nombre, prv_ruc_ced, dep_descripcion, oc_fecha,
--    oc_fecha_entrega, oc_subtotal, oc_iva, oc_total, estado_oc,
--    emp_nombres || emp_apellidos AS generado_por, des_valor AS descuento_pct
--
--  DETALLE devuelve:
--    id_producto, pro_nombre, um_descripcion, pxo_cantidad, pxo_valor,
--    pxo_subtotal, estado_pxoc
--
--  USO DESDE PSQL:
--    BEGIN;
--    CALL comercial.sp_visualizar_compra('OC00001', 'cur_cab', 'cur_det');
--    FETCH ALL FROM cur_cab;
--    FETCH ALL FROM cur_det;
--    COMMIT;
--
--  OPTIMIZACIÓN:
--    Los OPEN … FOR SELECT usan únicamente columnas de PK/FK para filtros,
--    garantizando acceso por índice. No hay cursores FOR LOOP que materialicen
--    la tabla completa; el resultado se entrega lazy al cliente.
--
--  ÍNDICES UTILIZADOS:
--    pk_compras     (id_compra)            — lookup O(log n)
--    pk_proveedores (id_proveedor)         — JOIN por FK
--    pk_empleados   (id_empleado)          — JOIN por FK
--    pk_proxoc      (id_compra, id_prod)   — rango filtrado por id_compra
--    pk_productos   (id_producto)          — JOIN por FK
--    pk_unidades_medidas (id_unidad_medida)— JOIN por FK

DROP PROCEDURE IF EXISTS comercial.sp_visualizar_compra(CHAR, REFCURSOR, REFCURSOR);

CREATE OR REPLACE PROCEDURE comercial.sp_visualizar_compra(
    IN    p_id_compra   CHAR(7),
    INOUT cur_cabecera  REFCURSOR,
    INOUT cur_detalle   REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe BOOLEAN;
BEGIN
    -- ────────────────────────────────────────────────────────────────────
    --  VALIDACIÓN: la OC solicitada debe existir
    --  (Lookup por pk_compras → O(log n); evita abrir cursores vacíos)
    -- ────────────────────────────────────────────────────────────────────
    SELECT EXISTS (
        SELECT 1 FROM comercial.compras WHERE id_compra = p_id_compra
    ) INTO v_existe;

    IF NOT v_existe THEN
        RAISE EXCEPTION '[sp_visualizar_compra] La OC % no existe.', p_id_compra;
    END IF;

    -- ────────────────────────────────────────────────────────────────────
    --  CURSOR 1 — CABECERA DE LA OC
    --  JOIN con proveedores, empleados, departamentos y th_descuentos.
    --  LEFT JOIN en descuento porque puede ser NULL.
    -- ────────────────────────────────────────────────────────────────────
    OPEN cur_cabecera FOR
        SELECT
            c.id_compra                                             AS "Número OC",
            p.id_proveedor                                         AS "ID Proveedor",
            p.prv_nombre                                           AS "Proveedor",
            p.prv_ruc_ced                                          AS "RUC/CI",
            p.prv_mail                                             AS "Email Proveedor",
            d.dep_descripcion                                      AS "Departamento",
            c.oc_fecha                                             AS "Fecha Creación",
            c.oc_fecha_entrega                                     AS "Fecha Entrega",
            c.oc_subtotal                                          AS "Subtotal ($)",
            COALESCE(td.des_valor, 0)                             AS "% Descuento",
            c.oc_iva                                               AS "IVA 15% ($)",
            c.oc_total                                             AS "Total ($)",
            c.estado_oc                                            AS "Estado",
            e.emp_nombres || ' ' || e.emp_apellidos               AS "Generado Por"
          FROM comercial.compras          c
          JOIN comercial.proveedores      p  ON p.id_proveedor  = c.id_proveedor
          JOIN comercial.empleados        e  ON e.id_empleado   = c.id_empleado
          JOIN comercial.departamentos    d  ON d.id_departamento = c.id_departamento
          LEFT JOIN comercial.th_descuentos td ON td.id_descuento = c.id_descuento
         WHERE c.id_compra = p_id_compra;

    -- ────────────────────────────────────────────────────────────────────
    --  CURSOR 2 — DETALLE DE LÍNEAS DE LA OC
    --  JOIN con productos y unidades_medidas.
    --  Ordenado por id_producto para presentación consistente.
    -- ────────────────────────────────────────────────────────────────────
    OPEN cur_detalle FOR
        SELECT
            ROW_NUMBER() OVER (ORDER BY px.id_producto)   AS "Línea",
            px.id_producto                                 AS "Código",
            pr.pro_nombre                                  AS "Producto",
            pr.pro_descripcion                             AS "Descripción",
            um.um_descripcion                              AS "Unidad Medida",
            px.pxo_cantidad                                AS "Cantidad",
            px.pxo_valor                                   AS "Precio Unitario ($)",
            px.pxo_subtotal                                AS "Subtotal Línea ($)",
            px.estado_pxoc                                 AS "Estado Línea"
          FROM comercial.proxoc         px
          JOIN comercial.productos      pr ON pr.id_producto       = px.id_producto
          JOIN comercial.unidades_medidas um ON um.id_unidad_medida = pr.fk_pro_um_compra
         WHERE px.id_compra = p_id_compra
         ORDER BY px.id_producto;

    -- NOTA: sp_visualizar_compra NO emite COMMIT porque solo abre cursores
    -- de lectura. Los cursores deben permanecer abiertos dentro de la
    -- transacción del llamador hasta que se haga FETCH. Ver ejemplo de uso.

EXCEPTION
    WHEN OTHERS THEN
        -- Cerrar cursores si estaban abiertos antes del error
        BEGIN
            CLOSE cur_cabecera;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            CLOSE cur_detalle;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RAISE EXCEPTION '[sp_visualizar_compra] FALLO al abrir cursores. Detalle: %', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_visualizar_compra(CHAR, REFCURSOR, REFCURSOR) IS
'Retorna la cabecera y el detalle de una OC mediante dos REFCURSOR.
 El llamador debe estar en una transacción BEGIN/COMMIT para poder hacer FETCH.
 Ejemplo: BEGIN; CALL sp_visualizar_compra(''OC00001'',''c1'',''c2'');
          FETCH ALL FROM c1; FETCH ALL FROM c2; COMMIT;';


-- ════════════════════════════════════════════════════════════════════════
--  EJEMPLOS DE USO
-- ════════════════════════════════════════════════════════════════════════

/*
──────────────────────────────────────────────────────────────
  EJEMPLO 1 — Crear una Orden de Compra
──────────────────────────────────────────────────────────────
CALL comercial.sp_crear_compra(
    'OC00001',                    -- p_id_compra
    'PRV0001',                    -- p_id_proveedor  (debe existir y estar ACT)
    'EMP0001',                    -- p_id_empleado   (Auxiliar de Compras ACT)
    'DEP',                        -- p_id_departamento
    '2026-05-30',                 -- p_fecha_entrega
    NULL,                         -- p_id_descuento  (NULL = sin descuento)
    '[
        {"id_producto":"PRD0001","cantidad":6,"valor_unitario":36.50},
        {"id_producto":"PRD0002","cantidad":12,"valor_unitario":0.08},
        {"id_producto":"PRD0003","cantidad":4,"valor_unitario":750.62}
     ]'::JSON
);

──────────────────────────────────────────────────────────────
  EJEMPLO 2 — Aprobar la OC generando Recibo y Asiento
──────────────────────────────────────────────────────────────
CALL comercial.sp_aprobar_compra(
    'OC00001',              -- p_id_compra
    'EMP0010',              -- p_id_aprobador (Jefe de Compras)
    'REC0001',              -- p_id_recibo    (nuevo ID de recepción)
    'ASI0001',              -- p_id_asiento   (nuevo ID de asiento)
    'B01',                  -- p_id_bodega
    '1.1.03.01.001',        -- p_cta_inventario  (Inventario mercadería)
    '1.1.04.01.001',        -- p_cta_iva_compras (Crédito tributario IVA)
    '2.1.01.01.001'         -- p_cta_proveedores (Cuentas por pagar)
);

──────────────────────────────────────────────────────────────
  EJEMPLO 3 — Anular una OC en estado ABI
──────────────────────────────────────────────────────────────
CALL comercial.sp_anular_compra(
    'OC00002',                               -- p_id_compra
    'EMP0010',                               -- p_id_empleado
    'Proveedor no cumplió condiciones pactadas'  -- p_motivo
);

──────────────────────────────────────────────────────────────
  EJEMPLO 4 — Visualizar una OC completa (requiere transacción explícita)
──────────────────────────────────────────────────────────────
BEGIN;
    CALL comercial.sp_visualizar_compra('OC00001', 'cur_cab', 'cur_det');
    FETCH ALL FROM cur_cab;   -- Cabecera con JOIN a proveedor, empleado, dpto
    FETCH ALL FROM cur_det;   -- Detalle con JOIN a productos y unidades de medida
COMMIT;
*/

-- ████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT — COMERCIAL_SP_COMPRAS_PG16.sql
-- ████████████████████████████████████████████████████████████████████████
