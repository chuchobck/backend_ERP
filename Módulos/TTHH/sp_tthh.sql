-- ████████████████████████████████████████████████████████████████████████████
-- ██  STORED PROCEDURES — MÓDULO TALENTO HUMANO / ROL DE PAGOS              ██
-- ██  Sistema: COMERCIAL  |  BD: PostgreSQL 16  |  Schema: comercial        ██
-- ██  JW Cóndor | diciembre 2025                                            ██
-- ██                                                                        ██
-- ██  PROCEDURES INCLUIDOS:                                                 ██
-- ██    1. sp_crear_rolpago      → Crea cabecera + líneas automáticas       ██
-- ██    2. sp_aprobar_rolpago    → ABI→APR + genera asiento contable        ██
-- ██    3. sp_anular_rolpago     → ABI/APR→ANU + reversión contable         ██
-- ██    4. sp_visualizar_rolpago → Retorna cursores cabecera + detalle      ██
-- ██                                                                        ██
-- ██  ATOMICIDAD:                                                           ██
-- ██    • Cada procedure usa COMMIT explícito al final del flujo feliz.     ██
-- ██    • El bloque EXCEPTION ejecuta ROLLBACK antes de re-lanzar el error, ██
-- ██      garantizando que no quede ninguna fila parcialmente insertada.    ██
-- ██    • Los COMMIT intermedios se evitan para que toda la operación sea   ██
-- ██      una única unidad atómica.  En aprobación, el asiento contable     ██
-- ██      y el cambio de estado se confirman en el mismo COMMIT.            ██
-- ██                                                                        ██
-- ██  OPTIMIZACIÓN (>400 000 registros):                                   ██
-- ██    • Todas las búsquedas usan PK/UK: pk_rol_pagos, pk_empleados,      ██
-- ██      pk_conceptos_nomina, pk_centros_costo, pk_asientos.               ██
-- ██    • El cursor de conceptos filtra sobre pk_conceptos_nomina (CHAR 4). ██
-- ██    • Se evita cualquier FULL SCAN; los UPDATE/SELECT usan id_rol_pago. ██
-- ██                                                                        ██
-- ██  PRE-REQUISITO: haber ejecutado COMERCIAL_DDL_PG16.sql completo       ██
-- ████████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════════
--  PROCEDURE 1 ── sp_crear_rolpago
-- ────────────────────────────────────────────────────────────────────────────
--  PROPÓSITO : Genera la cabecera del Rol de Pagos y calcula automáticamente
--              las líneas de detalle para todos los conceptos de nómina
--              FIJOS y ACTIVOS, aplicando el porcentaje sobre el sueldo base.
--              Los conceptos NO fijos (préstamos, impuesto renta, etc.) deben
--              añadirse después con sp_agregar_concepto_variable si se requiere.
--
--  PARÁMETROS DE ENTRADA:
--    p_id_rol_pago  CHAR(7)   → ID único del nuevo Rol de Pagos (ej. 'RPL0001')
--    p_id_empleado  CHAR(7)   → Código del empleado propietario del rol
--    p_id_centro    CHAR(5)   → Centro de costo (puede ser NULL)
--    p_anio         SMALLINT  → Año del período (ej. 2025)
--    p_mes          SMALLINT  → Mes del período (1-12)
--    p_id_usuario   CHAR(7)   → Empleado que ejecuta la operación (auditoría)
--
--  PARÁMETRO DE SALIDA:
--    p_resultado    TEXT      → Mensaje de éxito o error descriptivo
--
--  ESTADOS VÁLIDOS RESULTANTES: ABI
--  FLUJO DE ESTADOS: (nuevo) → ABI
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_crear_rolpago(
    IN  p_id_rol_pago   CHAR(7),
    IN  p_id_empleado   CHAR(7),
    IN  p_id_centro     CHAR(5),
    IN  p_anio          SMALLINT,
    IN  p_mes           SMALLINT,
    IN  p_id_usuario    CHAR(7),
    OUT p_resultado     TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Variables para datos del empleado
    v_emp_sueldo       NUMERIC(14,2);
    v_estado_emp       CHAR(3);
    v_emp_nombre       TEXT;

    -- Acumuladores de totales
    v_total_ingresos   NUMERIC(14,2) := 0.00;
    v_total_descuentos NUMERIC(14,2) := 0.00;

    -- Control de líneas de detalle
    v_linea            INTEGER := 0;
    v_valor_concepto   NUMERIC(14,2);

    -- Registro de iteración de conceptos
    r_con              RECORD;

BEGIN
    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 1 ─ VALIDACIONES DE INTEGRIDAD PREVIAS
    -- ────────────────────────────────────────────────────────────────────────

    -- 1.1 Verificar que el empleado existe y está activo
    --     Accede directamente por PK (pk_empleados) → índice puntual, O(log n)
    SELECT e.emp_sueldo,
           e.estado_emp,
           e.emp_apellidos || ' ' || e.emp_nombres
    INTO   v_emp_sueldo, v_estado_emp, v_emp_nombre
    FROM   comercial.empleados e
    WHERE  e.id_empleado = p_id_empleado;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'EMPLEADO_NO_EXISTE | El empleado [%] no existe en el sistema.',
            p_id_empleado;
    END IF;

    IF v_estado_emp <> 'ACT' THEN
        RAISE EXCEPTION
            'EMPLEADO_INACTIVO | El empleado [%] – % no está activo (estado: %).',
            p_id_empleado, v_emp_nombre, v_estado_emp;
    END IF;

    IF v_emp_sueldo <= 0 THEN
        RAISE EXCEPTION
            'SUELDO_CERO | El empleado [%] tiene sueldo base = 0. Registre el sueldo antes de generar el rol.',
            p_id_empleado;
    END IF;

    -- 1.2 Evitar ID de rol duplicado (usa PK pk_rol_pagos)
    IF EXISTS (
        SELECT 1 FROM comercial.rol_pagos
        WHERE  id_rol_pago = p_id_rol_pago
    ) THEN
        RAISE EXCEPTION
            'ID_ROL_DUPLICADO | El identificador [%] ya está registrado.',
            p_id_rol_pago;
    END IF;

    -- 1.3 Evitar doble rol para mismo empleado/período (usa UNIQUE uq_rol_emp_periodo)
    IF EXISTS (
        SELECT 1 FROM comercial.rol_pagos
        WHERE  id_empleado = p_id_empleado
          AND  rpl_anio    = p_anio
          AND  rpl_mes     = p_mes
    ) THEN
        RAISE EXCEPTION
            'ROL_PERIODO_DUPLICADO | Ya existe un Rol de Pagos para el empleado [%] en el período %/%.',
            p_id_empleado, p_anio, p_mes;
    END IF;

    -- 1.4 Validar rango del mes
    IF p_mes NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION
            'MES_INVALIDO | El mes [%] está fuera del rango válido (1-12).',
            p_mes;
    END IF;

    -- 1.5 Validar centro de costo si se proporcionó (usa PK pk_centros_costo)
    IF p_id_centro IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM comercial.centros_costo
            WHERE  id_centro  = p_id_centro
              AND  estado_cco = 'ACT'
        ) THEN
            RAISE EXCEPTION
                'CENTRO_INVALIDO | El centro de costo [%] no existe o está inactivo.',
                p_id_centro;
        END IF;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 2 ─ INSERTAR CABECERA DEL ROL (estado inicial: ABI)
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO comercial.rol_pagos (
        id_rol_pago,
        id_empleado,
        id_centro,
        id_asiento,         -- NULL hasta la aprobación
        rpl_anio,
        rpl_mes,
        rpl_sueldo_base,    -- SNAPSHOT del sueldo actual (no varía si hay aumento posterior)
        rpl_total_ingresos,
        rpl_total_descuentos,
        rpl_fecha_pago,
        estado_rpl
    )
    VALUES (
        p_id_rol_pago,
        p_id_empleado,
        p_id_centro,
        NULL,
        p_anio,
        p_mes,
        v_emp_sueldo,
        0.00,               -- se recalcula en Bloque 4
        0.00,               -- se recalcula en Bloque 4
        NULL,
        'ABI'
    );

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 3 ─ GENERAR LÍNEAS DE DETALLE (conceptos fijos activos)
    --
    --  Estrategia de cursor: itera sobre conceptos_nomina con estado='ACT'
    --  y con_es_fijo=TRUE, ordenado por id_concepto (PK CHAR 4).
    --  El ORDER BY sobre la PK garantiza uso del índice pk_conceptos_nomina
    --  y resultados deterministas.
    -- ────────────────────────────────────────────────────────────────────────

    -- 3.1 Sueldo mensual (concepto '1000', siempre el primero y en monto fijo)
    v_linea := 1;
    INSERT INTO comercial.rol_pagos_det (
        id_rol_pago, rpd_linea, id_concepto, rpd_tipo,
        rpd_cantidad, rpd_valor, estado_rpd
    )
    VALUES (
        p_id_rol_pago, v_linea, '1000', 'ING',
        30,             -- 30 días del mes
        v_emp_sueldo,
        'ABI'
    );
    v_total_ingresos := v_emp_sueldo;

    -- 3.2 Resto de conceptos fijos con porcentaje > 0
    FOR r_con IN
        SELECT cn.id_concepto,
               cn.con_tipo,
               cn.con_porcentaje
        FROM   comercial.conceptos_nomina cn
        WHERE  cn.estado_con   = 'ACT'
          AND  cn.con_es_fijo  = TRUE
          AND  cn.id_concepto <> '1000'   -- sueldo base ya insertado
          AND  cn.con_porcentaje > 0
        ORDER BY cn.id_concepto             -- recorre la PK en orden
    LOOP
        -- Calcular el valor redondeado a 2 decimales
        v_valor_concepto :=
            ROUND(v_emp_sueldo * r_con.con_porcentaje / 100.0, 2);

        v_linea := v_linea + 1;

        INSERT INTO comercial.rol_pagos_det (
            id_rol_pago, rpd_linea, id_concepto, rpd_tipo,
            rpd_cantidad, rpd_valor, estado_rpd
        )
        VALUES (
            p_id_rol_pago, v_linea, r_con.id_concepto, r_con.con_tipo,
            1, v_valor_concepto, 'ABI'
        );

        -- Acumular según tipo
        IF r_con.con_tipo = 'ING' THEN
            v_total_ingresos := v_total_ingresos + v_valor_concepto;
        ELSE
            v_total_descuentos := v_total_descuentos + v_valor_concepto;
        END IF;
    END LOOP;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 4 ─ ACTUALIZAR TOTALES EN CABECERA
    --            UPDATE directo por PK → O(log n), sin full scan
    -- ────────────────────────────────────────────────────────────────────────
    UPDATE comercial.rol_pagos
    SET    rpl_total_ingresos   = v_total_ingresos,
           rpl_total_descuentos = v_total_descuentos
           -- rpl_neto es GENERATED STORED → se recalcula automáticamente
    WHERE  id_rol_pago = p_id_rol_pago;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 5 ─ AUDITORÍA
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion, id_registro, valor_nuevo
    )
    VALUES (
        COALESCE(p_id_usuario, SESSION_USER),
        'rol_pagos',
        'INSERT',
        p_id_rol_pago,
        FORMAT(
            'emp:%s | periodo:%s/%s | sueldo:%.2f | ingresos:%.2f | '
            'descuentos:%.2f | neto:%.2f | lineas:%s',
            p_id_empleado, p_anio, p_mes,
            v_emp_sueldo, v_total_ingresos, v_total_descuentos,
            v_total_ingresos - v_total_descuentos, v_linea
        )
    );

    -- ────────────────────────────────────────────────────────────────────────
    -- COMMIT EXPLÍCITO — confirma cabecera + todas las líneas como una unidad
    -- ────────────────────────────────────────────────────────────────────────
    COMMIT;

    p_resultado := FORMAT(
        'OK | Rol [%s] creado para %s (%s). Período: %s/%s | '
        'Ingresos: %.2f | Descuentos: %.2f | Neto: %.2f | Líneas: %s',
        p_id_rol_pago, v_emp_nombre, p_id_empleado,
        p_anio, p_mes,
        v_total_ingresos, v_total_descuentos,
        v_total_ingresos - v_total_descuentos, v_linea
    );

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK revierte la cabecera y TODAS las líneas de detalle
        -- insertadas en esta llamada, evitando registros huérfanos.
        ROLLBACK;
        p_resultado := FORMAT('ERROR [%s] | %s', SQLSTATE, SQLERRM);
        RAISE;  -- re-lanza para que el caller reciba el error también
END;
$$;

COMMENT ON PROCEDURE comercial.sp_crear_rolpago IS
    'Crea Rol de Pagos (ABI) con líneas de conceptos fijos. '
    'Atómico: COMMIT al final; ROLLBACK en EXCEPTION.';


-- ════════════════════════════════════════════════════════════════════════════
--  PROCEDURE 2 ── sp_aprobar_rolpago
-- ────────────────────────────────────────────────────────────────────────────
--  PROPÓSITO : Aprueba un Rol de Pagos en estado ABI, transicionándolo a APR.
--              Genera el asiento contable de nómina (partida doble) y lo
--              vincula al rol. Actualiza todas las líneas de detalle a APR.
--
--  LÓGICA CONTABLE (partida doble):
--    DEBE  → Gasto Sueldos (cuenta de gastos operativos)  = total_ingresos
--    HABER → Sueldos por Pagar (pasivo corriente)          = neto (ingresos - descuentos)
--    HABER → IESS/Retenciones por Pagar (pasivo corriente) = total_descuentos
--    ─────────────────────────────────────────────────────────────────────
--    Verificación: DEBE = neto + descuentos = total_ingresos  ✓
--    El trigger trg_asi_partida_doble_ins valida automáticamente.
--
--  PARÁMETROS DE ENTRADA:
--    p_id_rol_pago      CHAR(7)   → Rol a aprobar (debe estar en estado ABI)
--    p_id_asiento_nuevo CHAR(7)   → ID para el nuevo asiento contable
--    p_cta_gasto        CHAR(15)  → Cuenta DEBE: Gasto de Personal (ej. '6.1.01.01.01')
--    p_cta_pagar_emp    CHAR(15)  → Cuenta HABER: Sueldos por Pagar empleado
--    p_cta_pagar_des    CHAR(15)  → Cuenta HABER: Retenciones/Descuentos por Pagar
--    p_id_usuario       CHAR(7)   → Empleado que aprueba (auditoría y control)
--
--  PARÁMETRO DE SALIDA:
--    p_resultado        TEXT      → Mensaje descriptivo de éxito o error
--
--  FLUJO DE ESTADOS: ABI → APR
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_aprobar_rolpago(
    IN  p_id_rol_pago       CHAR(7),
    IN  p_id_asiento_nuevo  CHAR(7),
    IN  p_cta_gasto         CHAR(15),   -- DEBE: gasto de sueldos
    IN  p_cta_pagar_emp     CHAR(15),   -- HABER: neto a depositar al empleado
    IN  p_cta_pagar_des     CHAR(15),   -- HABER: descuentos retenidos (IESS, etc.)
    IN  p_id_usuario        CHAR(7),
    OUT p_resultado         TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Datos del rol actual
    v_estado_rpl        CHAR(3);
    v_id_empleado       CHAR(7);
    v_rpl_anio          SMALLINT;
    v_rpl_mes           SMALLINT;
    v_total_ingresos    NUMERIC(14,2);
    v_total_descuentos  NUMERIC(14,2);
    v_neto              NUMERIC(14,2);
    v_sueldo_base       NUMERIC(14,2);
    v_emp_nombre        TEXT;

    -- Validación de cuentas contables
    v_cta_gasto_ok      BOOLEAN := FALSE;
    v_cta_emp_ok        BOOLEAN := FALSE;
    v_cta_des_ok        BOOLEAN := FALSE;

BEGIN
    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 1 ─ LECTURA Y VALIDACIÓN DEL ROL (acceso por PK pk_rol_pagos)
    -- ────────────────────────────────────────────────────────────────────────

    SELECT rp.estado_rpl,
           rp.id_empleado,
           rp.rpl_anio,
           rp.rpl_mes,
           rp.rpl_total_ingresos,
           rp.rpl_total_descuentos,
           rp.rpl_neto,           -- columna GENERATED STORED
           rp.rpl_sueldo_base,
           e.emp_apellidos || ' ' || e.emp_nombres
    INTO   v_estado_rpl, v_id_empleado, v_rpl_anio, v_rpl_mes,
           v_total_ingresos, v_total_descuentos, v_neto, v_sueldo_base,
           v_emp_nombre
    FROM   comercial.rol_pagos  rp
    JOIN   comercial.empleados  e  ON e.id_empleado = rp.id_empleado
    WHERE  rp.id_rol_pago = p_id_rol_pago;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROL_NO_EXISTE | El Rol de Pagos [%] no existe.',
            p_id_rol_pago;
    END IF;

    -- Solo se puede aprobar desde estado ABI
    IF v_estado_rpl <> 'ABI' THEN
        RAISE EXCEPTION
            'ESTADO_INVALIDO | El rol [%] está en estado [%]. Solo se puede aprobar desde ABI.',
            p_id_rol_pago, v_estado_rpl;
    END IF;

    -- Validar que haya ingresos registrados
    IF v_total_ingresos <= 0 THEN
        RAISE EXCEPTION
            'SIN_INGRESOS | El rol [%] no tiene líneas de ingresos. Agregue conceptos antes de aprobar.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 2 ─ VALIDAR CUENTAS CONTABLES (acceso por PK pk_cuentas)
    --            Garantiza que las cuentas existen y están activas
    --            antes de intentar crear el asiento.
    -- ────────────────────────────────────────────────────────────────────────
    SELECT EXISTS(SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_gasto    AND estado_cue = 'ACT'),
           EXISTS(SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_pagar_emp AND estado_cue = 'ACT'),
           EXISTS(SELECT 1 FROM comercial.cuentas WHERE id_cuenta = p_cta_pagar_des AND estado_cue = 'ACT')
    INTO   v_cta_gasto_ok, v_cta_emp_ok, v_cta_des_ok;

    IF NOT v_cta_gasto_ok THEN
        RAISE EXCEPTION
            'CUENTA_INVALIDA | La cuenta de Gasto [%] no existe o está inactiva.',
            p_cta_gasto;
    END IF;
    IF NOT v_cta_emp_ok THEN
        RAISE EXCEPTION
            'CUENTA_INVALIDA | La cuenta de Sueldos por Pagar [%] no existe o está inactiva.',
            p_cta_pagar_emp;
    END IF;
    IF NOT v_cta_des_ok THEN
        RAISE EXCEPTION
            'CUENTA_INVALIDA | La cuenta de Descuentos por Pagar [%] no existe o está inactiva.',
            p_cta_pagar_des;
    END IF;

    -- Verificar que el ID de asiento no esté en uso (PK pk_asientos)
    IF EXISTS (SELECT 1 FROM comercial.asientos WHERE id_asiento = p_id_asiento_nuevo) THEN
        RAISE EXCEPTION
            'ASIENTO_DUPLICADO | El identificador de asiento [%] ya está en uso.',
            p_id_asiento_nuevo;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 3 ─ CREAR ASIENTO CONTABLE DE NÓMINA
    --
    --   El trigger trg_asi_partida_doble_ins verificará que DEBE = HABER.
    --   Estado inicial: PEN (pendiente de validación contable)
    -- ────────────────────────────────────────────────────────────────────────

    INSERT INTO comercial.asientos (
        id_asiento,
        asi_descripcion,
        asi_total_debe,
        asi_total_haber,
        asi_fecha_hora,
        user_id,
        estado_asi
    )
    VALUES (
        p_id_asiento_nuevo,
        FORMAT('Nómina %s/%s – %s [%s]',
            v_rpl_anio, v_rpl_mes, v_emp_nombre, p_id_rol_pago),
        v_total_ingresos,   -- DEBE  = total de ingresos brutos
        v_total_ingresos,   -- HABER = neto + descuentos = total_ingresos  ✓
        CURRENT_TIMESTAMP,
        COALESCE(p_id_usuario, SESSION_USER),
        'PEN'
    );

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 4 ─ INSERTAR PARTIDAS DEL ASIENTO (ctaxasi)
    --
    --  Línea DEBE  : Gasto de Personal (cuenta de resultados - gastos)
    --  Línea HABER1: Sueldos Netos por Pagar al empleado
    --  Línea HABER2: Descuentos retenidos por pagar (IESS, etc.)
    --               Se omite si total_descuentos = 0 para no violar chk_cxa_no_cero
    -- ────────────────────────────────────────────────────────────────────────

    -- Partida DEBE: Gasto de Personal
    INSERT INTO comercial.ctaxasi (
        id_asiento, id_cuenta,
        cxa_debe, cxa_haber, estado_cxa
    )
    VALUES (
        p_id_asiento_nuevo, p_cta_gasto,
        v_total_ingresos, 0.00, 'ACT'
    );

    -- Partida HABER: Sueldo neto a depositar al empleado
    IF v_neto > 0 THEN
        INSERT INTO comercial.ctaxasi (
            id_asiento, id_cuenta,
            cxa_debe, cxa_haber, estado_cxa
        )
        VALUES (
            p_id_asiento_nuevo, p_cta_pagar_emp,
            0.00, v_neto, 'ACT'
        );
    END IF;

    -- Partida HABER: Descuentos retenidos (IESS, IR, préstamos, etc.)
    IF v_total_descuentos > 0 THEN
        INSERT INTO comercial.ctaxasi (
            id_asiento, id_cuenta,
            cxa_debe, cxa_haber, estado_cxa
        )
        VALUES (
            p_id_asiento_nuevo, p_cta_pagar_des,
            0.00, v_total_descuentos, 'ACT'
        );
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 5 ─ ACTUALIZAR CABECERA DEL ROL: ABI → APR + vincular asiento
    -- ────────────────────────────────────────────────────────────────────────
    UPDATE comercial.rol_pagos
    SET    estado_rpl    = 'APR',
           id_asiento    = p_id_asiento_nuevo,
           rpl_fecha_pago = CURRENT_DATE
    WHERE  id_rol_pago   = p_id_rol_pago
      AND  estado_rpl    = 'ABI';   -- doble chequeo para evitar race condition

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'CONCURRENCIA | El rol [%] fue modificado por otro proceso. Reintente.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 6 ─ ACTUALIZAR TODAS LAS LÍNEAS DE DETALLE: ABI → APR
    --            UPDATE masivo por FK fk_rpd_rol (índice implícito en PK compuesta)
    -- ────────────────────────────────────────────────────────────────────────
    UPDATE comercial.rol_pagos_det
    SET    estado_rpd = 'APR'
    WHERE  id_rol_pago = p_id_rol_pago
      AND  estado_rpd  = 'ABI';

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 7 ─ AUDITORÍA
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion, id_registro,
        valor_anterior, valor_nuevo
    )
    VALUES (
        COALESCE(p_id_usuario, SESSION_USER),
        'rol_pagos',
        'UPDATE',
        p_id_rol_pago,
        'estado:ABI',
        FORMAT('estado:APR | asiento:%s | neto:%.2f',
            p_id_asiento_nuevo, v_neto)
    );

    -- ────────────────────────────────────────────────────────────────────────
    -- COMMIT EXPLÍCITO — asiento + partidas + cambio de estado en un único
    -- bloque atómico. El trigger de partida doble se disparó en el INSERT
    -- de asientos; si falló, el EXCEPTION a continuación hace ROLLBACK de todo.
    -- ────────────────────────────────────────────────────────────────────────
    COMMIT;

    p_resultado := FORMAT(
        'OK | Rol [%s] APROBADO para %s. Período: %s/%s | '
        'Sueldo base: %.2f | Ingresos: %.2f | Descuentos: %.2f | '
        'Neto depositado: %.2f | Asiento contable: [%s]',
        p_id_rol_pago, v_emp_nombre, v_rpl_anio, v_rpl_mes,
        v_sueldo_base, v_total_ingresos, v_total_descuentos,
        v_neto, p_id_asiento_nuevo
    );

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK revierte: asiento, ctaxasi, UPDATE del rol y de detalles.
        -- Garantiza que no quede el rol en estado inconsistente (ej. APR sin asiento).
        ROLLBACK;
        p_resultado := FORMAT('ERROR [%s] | %s', SQLSTATE, SQLERRM);
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_aprobar_rolpago IS
    'Aprueba Rol (ABI→APR), genera asiento contable de nómina (partida doble) '
    'y actualiza estado de todas las líneas. Atómico: COMMIT al final; ROLLBACK en EXCEPTION.';


-- ════════════════════════════════════════════════════════════════════════════
--  PROCEDURE 3 ── sp_anular_rolpago
-- ────────────────────────────────────────────────────────────────────────────
--  PROPÓSITO : Anula un Rol de Pagos que esté en estado ABI o APR.
--
--  REGLAS DE NEGOCIO:
--    • Si el rol está en ABI  → anulación directa, sin impacto contable.
--    • Si el rol está en APR  → se revierte el asiento contable vinculado
--        (estado del asiento: APR → ANU, partidas a INA).
--    • Si el rol ya está en ANU → error; no se puede anular dos veces.
--    • La anulación de un rol APR genera una nueva entrada de auditoría
--        separada para el asiento revertido.
--
--  PARÁMETROS DE ENTRADA:
--    p_id_rol_pago  CHAR(7)   → Rol a anular
--    p_motivo       VARCHAR   → Razón de la anulación (obligatorio; mín 10 chars)
--    p_id_usuario   CHAR(7)   → Empleado que autoriza la anulación
--
--  PARÁMETRO DE SALIDA:
--    p_resultado    TEXT      → Mensaje descriptivo de éxito o error
--
--  FLUJO DE ESTADOS: ABI → ANU  |  APR → ANU (+ reversión contable)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_anular_rolpago(
    IN  p_id_rol_pago  CHAR(7),
    IN  p_motivo       VARCHAR(200),
    IN  p_id_usuario   CHAR(7),
    OUT p_resultado    TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_rpl       CHAR(3);
    v_id_asiento       CHAR(7);
    v_estado_asiento   CHAR(3);
    v_id_empleado      CHAR(7);
    v_rpl_anio         SMALLINT;
    v_rpl_mes          SMALLINT;
    v_neto             NUMERIC(14,2);
    v_emp_nombre       TEXT;
    v_estado_anterior  CHAR(3);

BEGIN
    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 1 ─ LECTURA DEL ROL (acceso por PK pk_rol_pagos)
    -- ────────────────────────────────────────────────────────────────────────
    SELECT rp.estado_rpl,
           rp.id_asiento,
           rp.id_empleado,
           rp.rpl_anio,
           rp.rpl_mes,
           rp.rpl_neto,
           e.emp_apellidos || ' ' || e.emp_nombres
    INTO   v_estado_rpl, v_id_asiento, v_id_empleado,
           v_rpl_anio, v_rpl_mes, v_neto, v_emp_nombre
    FROM   comercial.rol_pagos rp
    JOIN   comercial.empleados e ON e.id_empleado = rp.id_empleado
    WHERE  rp.id_rol_pago = p_id_rol_pago;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROL_NO_EXISTE | El Rol de Pagos [%] no existe.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 2 ─ VALIDACIONES DE ESTADO Y NEGOCIO
    -- ────────────────────────────────────────────────────────────────────────

    -- No se puede anular un rol ya anulado
    IF v_estado_rpl = 'ANU' THEN
        RAISE EXCEPTION
            'YA_ANULADO | El Rol [%] ya está en estado ANU. No se puede anular de nuevo.',
            p_id_rol_pago;
    END IF;

    -- El motivo es obligatorio y debe ser descriptivo
    IF p_motivo IS NULL OR LENGTH(TRIM(p_motivo)) < 10 THEN
        RAISE EXCEPTION
            'MOTIVO_REQUERIDO | Debe proveer un motivo descriptivo (mínimo 10 caracteres) para anular el rol [%].',
            p_id_rol_pago;
    END IF;

    -- El usuario que anula debe existir (acceso por PK pk_empleados)
    IF NOT EXISTS (
        SELECT 1 FROM comercial.empleados
        WHERE  id_empleado = p_id_usuario
    ) THEN
        RAISE EXCEPTION
            'USUARIO_INVALIDO | El usuario autorizador [%] no existe en el sistema.',
            p_id_usuario;
    END IF;

    -- Guardar estado anterior para auditoría
    v_estado_anterior := v_estado_rpl;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 3 ─ REVERSIÓN CONTABLE (solo si el rol estaba APR con asiento)
    -- ────────────────────────────────────────────────────────────────────────
    IF v_estado_rpl = 'APR' AND v_id_asiento IS NOT NULL THEN

        -- Leer estado actual del asiento (acceso por PK pk_asientos)
        SELECT estado_asi
        INTO   v_estado_asiento
        FROM   comercial.asientos
        WHERE  id_asiento = v_id_asiento;

        -- Verificar que el asiento no haya sido ya cerrado de otra forma
        IF v_estado_asiento = 'ANU' THEN
            RAISE EXCEPTION
                'ASIENTO_YA_ANULADO | El asiento contable [%] vinculado al rol [%] ya está anulado. '
                'Consulte con Contabilidad antes de proceder.',
                v_id_asiento, p_id_rol_pago;
        END IF;

        -- 3.1 Marcar partidas contables como inactivas (INA)
        --     UPDATE masivo por FK fk_cxa_asiento (PK compuesta asiento+cuenta)
        UPDATE comercial.ctaxasi
        SET    estado_cxa = 'INA'
        WHERE  id_asiento = v_id_asiento
          AND  estado_cxa = 'ACT';

        -- 3.2 Anular el asiento contable
        UPDATE comercial.asientos
        SET    estado_asi = 'ANU'
        WHERE  id_asiento = v_id_asiento
          AND  estado_asi <> 'ANU';

        -- Auditoría específica para la reversión contable
        INSERT INTO comercial.auditoria_sistema (
            usuario_db, tabla_afectada, operacion, id_registro,
            valor_anterior, valor_nuevo
        )
        VALUES (
            COALESCE(p_id_usuario, SESSION_USER),
            'asientos',
            'UPDATE',
            v_id_asiento,
            FORMAT('estado:%s', v_estado_asiento),
            FORMAT('estado:ANU | motivo_rol:%s', LEFT(p_motivo, 80))
        );

    ELSIF v_estado_rpl = 'APR' AND v_id_asiento IS NULL THEN
        -- Caso anómalo: APR sin asiento. Se registra advertencia pero se permite anular.
        RAISE WARNING
            'ADVERTENCIA | El rol [%] está APR pero no tiene asiento contable vinculado. '
            'Verifique la integridad con el área de Contabilidad.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 4 ─ ANULAR LÍNEAS DE DETALLE DEL ROL
    --            UPDATE masivo por id_rol_pago (primera columna de la PK compuesta)
    -- ────────────────────────────────────────────────────────────────────────
    UPDATE comercial.rol_pagos_det
    SET    estado_rpd = 'ANU'
    WHERE  id_rol_pago = p_id_rol_pago
      AND  estado_rpd <> 'ANU';

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 5 ─ ANULAR CABECERA DEL ROL
    -- ────────────────────────────────────────────────────────────────────────
    UPDATE comercial.rol_pagos
    SET    estado_rpl = 'ANU'
    WHERE  id_rol_pago = p_id_rol_pago
      AND  estado_rpl <> 'ANU';  -- protección contra concurrencia

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'CONCURRENCIA | El rol [%] fue modificado por otro proceso mientras se anulaba. Reintente.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 6 ─ AUDITORÍA DEL ROL
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO comercial.auditoria_sistema (
        usuario_db, tabla_afectada, operacion, id_registro,
        valor_anterior, valor_nuevo
    )
    VALUES (
        COALESCE(p_id_usuario, SESSION_USER),
        'rol_pagos',
        'UPDATE',
        p_id_rol_pago,
        FORMAT('estado:%s', v_estado_anterior),
        FORMAT(
            'estado:ANU | emp:%s | periodo:%s/%s | neto:%.2f | '
            'motivo:%s | autorizado_por:%s',
            v_id_empleado, v_rpl_anio, v_rpl_mes, v_neto,
            LEFT(p_motivo, 100), p_id_usuario
        )
    );

    -- ────────────────────────────────────────────────────────────────────────
    -- COMMIT EXPLÍCITO — rol + líneas + reversión contable en un único bloque
    -- ────────────────────────────────────────────────────────────────────────
    COMMIT;

    p_resultado := FORMAT(
        'OK | Rol [%s] ANULADO (estado anterior: %s) para %s. '
        'Período: %s/%s | Asiento revertido: %s | Motivo: %s',
        p_id_rol_pago, v_estado_anterior, v_emp_nombre,
        v_rpl_anio, v_rpl_mes,
        COALESCE(v_id_asiento, 'N/A'),
        LEFT(p_motivo, 80)
    );

EXCEPTION
    WHEN OTHERS THEN
        -- ROLLBACK deshace la anulación del asiento, ctaxasi y del rol.
        -- El rol queda en su estado original (ABI o APR) sin inconsistencias.
        ROLLBACK;
        p_resultado := FORMAT('ERROR [%s] | %s', SQLSTATE, SQLERRM);
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_anular_rolpago IS
    'Anula Rol (ABI/APR→ANU). Si estaba APR revierte el asiento contable. '
    'Atómico: COMMIT al final; ROLLBACK en EXCEPTION preserva estado original.';


-- ════════════════════════════════════════════════════════════════════════════
--  PROCEDURE 4 ── sp_visualizar_rolpago
-- ────────────────────────────────────────────────────────────────────────────
--  PROPÓSITO : Expone el Rol de Pagos completo a través de dos cursores:
--                • cur_cabecera → una fila con todos los datos del encabezado
--                  (empleado, período, sueldo base, totales, estado, asiento)
--                • cur_detalle  → una fila por cada concepto (ingresos primero,
--                  luego descuentos), con descripción, cantidad y valor.
--
--  USO DESDE EL CLIENTE:
--    BEGIN;
--    CALL comercial.sp_visualizar_rolpago('RPL0001', 'cur_cab', 'cur_det', v_res);
--    FETCH ALL FROM cur_cab;
--    FETCH ALL FROM cur_det;
--    COMMIT;
--
--  NOTA PostgreSQL: los cursores de tipo refcursor solo son accesibles
--  dentro del mismo bloque de transacción. El cliente DEBE hacer BEGIN
--  antes del CALL y COMMIT/ROLLBACK después de consumir los FETCH.
--
--  PARÁMETROS DE ENTRADA/SALIDA:
--    p_id_rol_pago   CHAR(7)   IN  → Rol a visualizar
--    p_cur_cabecera  refcursor INOUT → cursor con datos de cabecera
--    p_cur_detalle   refcursor INOUT → cursor con líneas de detalle
--
--  PARÁMETRO DE SALIDA:
--    p_resultado     TEXT OUT  → 'OK | ...' o 'ERROR | ...'
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE comercial.sp_visualizar_rolpago(
    IN    p_id_rol_pago   CHAR(7),
    INOUT p_cur_cabecera  refcursor,
    INOUT p_cur_detalle   refcursor,
    OUT   p_resultado     TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe  BOOLEAN;
BEGIN
    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 1 ─ VERIFICACIÓN RÁPIDA DE EXISTENCIA (PK pk_rol_pagos)
    -- ────────────────────────────────────────────────────────────────────────
    SELECT EXISTS(
        SELECT 1 FROM comercial.rol_pagos
        WHERE  id_rol_pago = p_id_rol_pago
    )
    INTO v_existe;

    IF NOT v_existe THEN
        RAISE EXCEPTION
            'ROL_NO_EXISTE | El Rol de Pagos [%] no existe en el sistema.',
            p_id_rol_pago;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 2 ─ CURSOR CABECERA
    --   JOIN con empleados (PK), departamentos (PK) y asientos (PK).
    --   Todos los JOINs usan claves primarias → Nested Loop con index scan.
    --   Se expone rpl_neto (GENERATED STORED) directamente, sin recalcular.
    -- ────────────────────────────────────────────────────────────────────────
    OPEN p_cur_cabecera FOR
        SELECT
            rp.id_rol_pago,
            rp.estado_rpl                                       AS estado,
            rp.rpl_anio                                         AS anio,
            rp.rpl_mes                                          AS mes,
            TO_CHAR(
                TO_DATE(rp.rpl_anio::TEXT || '-'
                    || LPAD(rp.rpl_mes::TEXT, 2, '0') || '-01',
                    'YYYY-MM-DD'),
                'Month YYYY'
            )                                                   AS periodo_label,
            e.id_empleado,
            e.emp_apellidos || ' ' || e.emp_nombres             AS empleado_nombre,
            e.emp_cedula,
            e.emp_email,
            e.emp_banco,
            e.emp_tipo_cuenta,
            e.emp_cuenta_bancaria,
            d.dep_descripcion                                   AS departamento,
            r.rol_descripcion                                   AS cargo,
            cc.cco_descripcion                                  AS centro_costo,
            rp.rpl_sueldo_base,
            rp.rpl_total_ingresos,
            rp.rpl_total_descuentos,
            rp.rpl_neto,                -- GENERATED STORED: ingresos - descuentos
            rp.rpl_fecha_pago,
            rp.id_asiento,
            asi.estado_asi              AS estado_asiento
        FROM  comercial.rol_pagos    rp
        JOIN  comercial.empleados    e   ON e.id_empleado    = rp.id_empleado
        JOIN  comercial.departamentos d  ON d.id_departamento = e.id_departamento
        JOIN  comercial.roles         r  ON r.id_rol          = e.id_rol
        LEFT  JOIN comercial.centros_costo cc
                                         ON cc.id_centro     = rp.id_centro
        LEFT  JOIN comercial.asientos    asi
                                         ON asi.id_asiento   = rp.id_asiento
        WHERE  rp.id_rol_pago = p_id_rol_pago;

    -- ────────────────────────────────────────────────────────────────────────
    -- BLOQUE 3 ─ CURSOR DETALLE
    --   JOIN con conceptos_nomina (PK pk_conceptos_nomina).
    --   ORDER BY: ingresos primero (ING), luego descuentos (DES),
    --             dentro de cada grupo ordenado por código de concepto.
    --   Se calculan subtotales acumulados con SUM() OVER para facilitar
    --   la renderización del rol en el cliente sin lógica adicional.
    -- ────────────────────────────────────────────────────────────────────────
    OPEN p_cur_detalle FOR
        SELECT
            rpd.rpd_linea,
            rpd.id_concepto,
            cn.con_descripcion                              AS concepto,
            rpd.rpd_tipo,
            CASE rpd.rpd_tipo
                WHEN 'ING' THEN 'Ingreso'
                WHEN 'DES' THEN 'Descuento'
            END                                             AS tipo_label,
            rpd.rpd_cantidad,
            rpd.rpd_valor,
            rpd.estado_rpd,
            -- Subtotales acumulados por tipo de concepto
            SUM(rpd.rpd_valor)
                FILTER (WHERE rpd.rpd_tipo = 'ING')
                OVER (PARTITION BY rpd.id_rol_pago)         AS subtotal_ingresos,
            SUM(rpd.rpd_valor)
                FILTER (WHERE rpd.rpd_tipo = 'DES')
                OVER (PARTITION BY rpd.id_rol_pago)         AS subtotal_descuentos
        FROM   comercial.rol_pagos_det rpd
        JOIN   comercial.conceptos_nomina cn
               ON cn.id_concepto = rpd.id_concepto
        WHERE  rpd.id_rol_pago = p_id_rol_pago
        ORDER BY
            -- Ingresos primero (1), Descuentos después (2)
            CASE rpd.rpd_tipo WHEN 'ING' THEN 1 WHEN 'DES' THEN 2 END,
            rpd.rpd_linea;

    -- ────────────────────────────────────────────────────────────────────────
    -- NOTA: sp_visualizar NO emite COMMIT/ROLLBACK porque no modifica datos.
    -- El manejo de la transacción queda en el cliente (BEGIN ... COMMIT)
    -- para mantener abiertos los cursores hasta consumirlos con FETCH.
    -- ────────────────────────────────────────────────────────────────────────

    p_resultado := FORMAT(
        'OK | Cursores abiertos para Rol [%s]. '
        'Consuma con: FETCH ALL FROM %s; FETCH ALL FROM %s;',
        p_id_rol_pago,
        p_cur_cabecera,
        p_cur_detalle
    );

EXCEPTION
    WHEN OTHERS THEN
        p_resultado := FORMAT('ERROR [%s] | %s', SQLSTATE, SQLERRM);
        RAISE;
END;
$$;

COMMENT ON PROCEDURE comercial.sp_visualizar_rolpago IS
    'Abre dos refcursors: p_cur_cabecera (encabezado + empleado) y '
    'p_cur_detalle (líneas ING/DES con subtotales window). '
    'Sin DML: el cliente gestiona la transacción para mantener los cursores.';


-- ════════════════════════════════════════════════════════════════════════════
--  EJEMPLOS DE USO
-- ════════════════════════════════════════════════════════════════════════════

/*
──────────────────────────────────────────────────────
  1. CREAR Rol de Pagos
──────────────────────────────────────────────────────
DO $$
DECLARE v_res TEXT;
BEGIN
    CALL comercial.sp_crear_rolpago(
        p_id_rol_pago => 'RPL0001',
        p_id_empleado => 'EMP-111',
        p_id_centro   => 'CCO01',
        p_anio        => 2025,
        p_mes         => 10,
        p_id_usuario  => 'EMP-111',
        p_resultado   => v_res
    );
    RAISE NOTICE '%', v_res;
END;
$$;

──────────────────────────────────────────────────────
  2. APROBAR Rol de Pagos (genera asiento contable)
──────────────────────────────────────────────────────
DO $$
DECLARE v_res TEXT;
BEGIN
    CALL comercial.sp_aprobar_rolpago(
        p_id_rol_pago       => 'RPL0001',
        p_id_asiento_nuevo  => 'ASI0001',
        p_cta_gasto         => '6.1.01.01.01',   -- Gasto Sueldos
        p_cta_pagar_emp     => '2.1.03.01.01',   -- Sueldos por Pagar
        p_cta_pagar_des     => '2.1.03.02.01',   -- IESS/Retenciones por Pagar
        p_id_usuario        => 'EMP-111',
        p_resultado         => v_res
    );
    RAISE NOTICE '%', v_res;
END;
$$;

──────────────────────────────────────────────────────
  3. ANULAR Rol de Pagos
──────────────────────────────────────────────────────
DO $$
DECLARE v_res TEXT;
BEGIN
    CALL comercial.sp_anular_rolpago(
        p_id_rol_pago => 'RPL0001',
        p_motivo      => 'Error en sueldo base; se regenerará con valor correcto.',
        p_id_usuario  => 'EMP-111',
        p_resultado   => v_res
    );
    RAISE NOTICE '%', v_res;
END;
$$;

──────────────────────────────────────────────────────
  4. VISUALIZAR Rol de Pagos (requiere BEGIN explícito)
──────────────────────────────────────────────────────
BEGIN;
    CALL comercial.sp_visualizar_rolpago(
        p_id_rol_pago  => 'RPL0001',
        p_cur_cabecera => 'cur_cab',
        p_cur_detalle  => 'cur_det',
        p_resultado    => NULL
    );
    FETCH ALL FROM cur_cab;   -- cabecera del rol con datos del empleado
    FETCH ALL FROM cur_det;   -- líneas de ingreso y descuento
COMMIT;
*/

-- ████████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT  — SP_TTHH_ROL_PAGOS_PG16.sql
-- ████████████████████████████████████████████████████████████████████████████
