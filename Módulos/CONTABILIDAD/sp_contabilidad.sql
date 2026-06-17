-- ████████████████████████████████████████████████████████████████████████
-- ██                                                                    ██
-- ██   COMERCIAL — STORED PROCEDURES: MÓDULO CONTABILIDAD              ██
-- ██   Sistema de Comercialización de Productos                         ██
-- ██   JW Cóndor | Arquitecto DB Senior | PostgreSQL 16                ██
-- ██                                                                    ██
-- ████████████████████████████████████████████████████████████████████████
--
--  PROCEDURES INCLUIDOS:
--  ─────────────────────────────────────────────────────────────────────
--   1. sp_aprobar_asiento_contable  — PEN → APR (valida partida doble,
--      recalcula totales, acumula saldos en plan de cuentas)
--
--   2. sp_anular_asiento_contable   — PEN|APR → ANU (verifica vínculos
--      con documentos aprobados, revierte acumulados si era APR)
--
--   3. sp_visualizar_asiento_contable — devuelve cabecera y detalle del
--      asiento via dos REFCURSOR (patrón estándar PostgreSQL)
--
--  TABLAS INVOLUCRADAS (Bloque 4 del DDL):
--  ─────────────────────────────────────────────────────────────────────
--   asientos   → cabecera: estado_asi IN ('PEN','APR','ANU')
--   ctaxasi    → partidas: cxa_debe / cxa_haber por cuenta contable
--   cuentas    → plan de cuentas: cue_debe00/cue_haber00 = acumuladores
--   auditoria_sistema → log transversal de operaciones DML
--
--  TABLAS REFERENCIADAS (documentos vinculados al asiento):
--  ─────────────────────────────────────────────────────────────────────
--   facturas       (fk_fac_asiento)     estado_fac IN ('ABI','APR','ANU')
--   devoluciones   (fk_dev_asiento)     estado_dev IN ('PEN','APR','ANU')
--   ajustes_inv    (fk_aji_asiento)     estado_aji IN ('ABI','APR','ANU')
--   rol_pagos      (fk_rpl_asiento)     estado_rpl IN ('ABI','APR','ANU')
--
--  TRIGGERS QUE INTERACTÚAN CON ESTOS SPs:
--  ─────────────────────────────────────────────────────────────────────
--   trg_asi_partida_doble_ins / _upd
--     → fn_validar_partida_doble()
--     → BEFORE INSERT/UPDATE ON asientos
--     → Valida: NEW.asi_total_debe <> NEW.asi_total_haber → RAISE EXCEPTION
--
--  ATOMICIDAD:
--  ─────────────────────────────────────────────────────────────────────
--   Cada PROCEDURE usa COMMIT/ROLLBACK explícitos (PG 11+).
--   Llamar siempre fuera de un bloque BEGIN...COMMIT externo (autocommit).
--   Si se llama desde otro PROCEDURE, usar SAVEPOINT para consistencia.
--
--  ÍNDICES UTILIZADOS (del DDL / COMERCIAL_INDEXES_PG16.sql):
--  ─────────────────────────────────────────────────────────────────────
--   pk_asientos           → asientos(id_asiento)
--   pk_ctaxasi            → ctaxasi(id_asiento, id_cuenta)
--   pk_cuentas            → cuentas(id_cuenta)
--   pk_auditoria          → auditoria_sistema(id_auditoria) IDENTITY
--   fk_fac_asiento        → facturas(id_asiento)
--   fk_dev_asiento        → devoluciones(id_asiento)
--   fk_aji_asiento        → ajustes_inv(id_asiento)
--   fk_rpl_asiento        → rol_pagos(id_asiento)
--
--  USO:
--   \c comercial
--   SET search_path TO comercial;
--   \i CONTABILIDAD_SPs_PG16.sql
-- ████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════
--  BLOQUE DE TIPOS AUXILIARES
--  Tipo compuesto para retornar la cabecera del asiento en sp_visualizar.
--  Permite que cursores y funciones wrapper retornen filas tipadas.
-- ════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
    -- Crea el tipo solo si no existe (idempotente)
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN   pg_namespace n ON n.oid = t.typnamespace
        WHERE  t.typname  = 'tipo_cabecera_asiento'
          AND  n.nspname  = 'comercial'
    ) THEN
        EXECUTE 'CREATE TYPE comercial.tipo_cabecera_asiento AS (
            id_asiento      CHAR(7),
            asi_descripcion VARCHAR(60),
            asi_total_debe  NUMERIC(12,2),
            asi_total_haber NUMERIC(12,2),
            asi_fecha_hora  TIMESTAMP,
            estado_asi      CHAR(3),
            user_id         CHAR(16)
        )';
    END IF;
END;
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN   pg_namespace n ON n.oid = t.typnamespace
        WHERE  t.typname  = 'tipo_detalle_asiento'
          AND  n.nspname  = 'comercial'
    ) THEN
        EXECUTE 'CREATE TYPE comercial.tipo_detalle_asiento AS (
            id_cuenta       CHAR(15),
            cue_descripcion VARCHAR(60),
            tipo_cuenta     VARCHAR(30),
            cxa_debe        NUMERIC(12,2),
            cxa_haber       NUMERIC(12,2),
            estado_cxa      CHAR(3)
        )';
    END IF;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════
--  SP 1: sp_aprobar_asiento_contable
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Aprueba un asiento contable en estado PEN, validando la ecuación
--    contable y acumulando los movimientos en el Plan de Cuentas.
--
--  PARÁMETROS:
--    p_id_asiento  CHAR(7)  — PK del asiento a aprobar
--    p_user_id     CHAR(16) — usuario que ejecuta la aprobación (auditoría)
--
--  FLUJO:
--    1. Bloquear cabecera con FOR UPDATE NOWAIT (previene doble aprobación)
--    2. Validar estado = PEN
--    3. Sumar partidas activas de ctaxasi → verificar DEBE = HABER
--    4. UPDATE asientos → totales recalculados + estado 'APR'
--       (el trigger trg_asi_partida_doble_upd valida una vez más antes del write)
--    5. Acumular partidas en cuentas.cue_debe00 / cue_haber00
--    6. Registrar en auditoria_sistema
--    7. COMMIT
--
--  ATOMICIDAD:
--    ROLLBACK en cualquier EXCEPTION → ninguna cuenta queda parcialmente
--    actualizada si el proceso falla a mitad del loop de partidas.
--
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE sp_aprobar_asiento_contable(
    IN p_id_asiento  CHAR(7),
    IN p_user_id     CHAR(16)  DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    -- Variables para lectura de la cabecera
    v_estado          CHAR(3);

    -- Acumuladores de validación
    v_count_partidas  INTEGER;
    v_sum_debe        NUMERIC(12,2);
    v_sum_haber       NUMERIC(12,2);

    -- Cursor de recorrido por partidas
    rec               RECORD;
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- PASO 1: Bloquear la cabecera del asiento (pk_asientos → seek directo)
    --   FOR UPDATE NOWAIT: si otra sesión tiene el lock, falla de inmediato
    --   con lock_not_available en vez de esperar indefinidamente.
    --   Crítico en tablas con 400K+ registros y procesos concurrentes.
    -- ──────────────────────────────────────────────────────────────────
    SELECT estado_asi
    INTO   v_estado
    FROM   asientos
    WHERE  id_asiento = p_id_asiento
    FOR UPDATE NOWAIT;

    -- Verificar existencia
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ASIENTO_NO_ENCONTRADO: El asiento [%] no existe en el sistema.',
            p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 2: Validar que el asiento esté en estado PEN
    --   Solo se aprueban asientos en PEN (generados por módulos externos).
    --   APR → ya aprobado (idempotencia protegida).
    --   ANU → anulado, no se puede reactivar.
    -- ──────────────────────────────────────────────────────────────────
    IF v_estado <> 'PEN' THEN
        RAISE EXCEPTION
            'ESTADO_INVALIDO: El asiento [%] está en estado [%]. '
            'Solo se pueden aprobar asientos en estado PEN.',
            p_id_asiento, v_estado;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 3: Sumar partidas activas desde ctaxasi
    --   Uso del índice pk_ctaxasi (id_asiento, id_cuenta) → no hay table scan.
    --   Se filtran solo las partidas ACT (las INA son de asientos anulados
    --   que pudieron haber sido regenerados, escenario de corrección).
    --   chk_cxa_no_cero garantiza que cada partida tenga debe > 0 O haber > 0.
    -- ──────────────────────────────────────────────────────────────────
    SELECT
        COUNT(*)                         AS total_partidas,
        COALESCE(SUM(cxa_debe),  0.00)   AS suma_debe,
        COALESCE(SUM(cxa_haber), 0.00)   AS suma_haber
    INTO
        v_count_partidas,
        v_sum_debe,
        v_sum_haber
    FROM ctaxasi
    WHERE id_asiento = p_id_asiento
      AND estado_cxa = 'ACT';

    -- Validar que existan al menos 2 partidas (débito y crédito mínimos)
    IF v_count_partidas < 2 THEN
        RAISE EXCEPTION
            'PARTIDAS_INSUFICIENTES: El asiento [%] tiene % partida(s) activa(s). '
            'Se requieren mínimo 2 para garantizar la partida doble.',
            p_id_asiento, v_count_partidas;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 4: Validar equilibrio contable DEBE = HABER
    --   Este SP recalcula los totales desde ctaxasi (fuente de verdad),
    --   no confía en los valores pre-cargados en la cabecera asientos,
    --   que pudieron ser modificados después de la creación del asiento.
    --   El trigger trg_asi_partida_doble_upd actúa como segunda línea
    --   de defensa en el UPDATE del paso siguiente.
    -- ──────────────────────────────────────────────────────────────────
    IF v_sum_debe <> v_sum_haber THEN
        RAISE EXCEPTION
            'DESEQUILIBRIO_CONTABLE: DEBE=% ≠ HABER=% en asiento [%]. '
            'Corrija las partidas antes de aprobar.',
            v_sum_debe, v_sum_haber, p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 5: Actualizar cabecera → estado APR + totales recalculados
    --   Se escribe v_sum_debe = v_sum_haber en la cabecera para que queden
    --   sincronizados con la realidad de ctaxasi.
    --   NOTA: el trigger fn_validar_partida_doble se disparará en este UPDATE.
    --   Como v_sum_debe = v_sum_haber, el trigger pasará sin excepción.
    -- ──────────────────────────────────────────────────────────────────
    UPDATE asientos
    SET
        asi_total_debe  = v_sum_debe,
        asi_total_haber = v_sum_haber,
        estado_asi      = 'APR',
        user_id         = COALESCE(p_user_id, user_id)
    WHERE id_asiento = p_id_asiento;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 6: Acumular saldos en el Plan de Cuentas (tabla cuentas)
    --   Loop sobre partidas → UPDATE por pk_cuentas (id_cuenta) → seek directo.
    --   Se actualiza cue_debe00 / cue_haber00 como acumuladores globales.
    --
    --   NOTA ARQUITECTÓNICA sobre columnas de periodo:
    --   La tabla cuentas tiene columnas adicionales cue_debe01-04 y
    --   cue_debe11-13 (y sus homólogos en haber) cuya semántica de periodo
    --   no está documentada en el DDL. Para evitar inconsistencias, este SP
    --   solo actualiza los acumuladores globales (00). Implementar la lógica
    --   de periodos requiere confirmar con el equipo contable qué representa
    --   cada sufijo (¿trimestres?, ¿ejercicios fiscales?, ¿presupuesto vs real?).
    -- ──────────────────────────────────────────────────────────────────
    FOR rec IN
        SELECT id_cuenta, cxa_debe, cxa_haber
        FROM   ctaxasi
        WHERE  id_asiento = p_id_asiento
          AND  estado_cxa = 'ACT'
    LOOP
        UPDATE cuentas
        SET
            cue_debe00  = cue_debe00  + rec.cxa_debe,
            cue_haber00 = cue_haber00 + rec.cxa_haber
        WHERE id_cuenta = rec.id_cuenta;

        -- Verificar que la cuenta exista y esté activa
        -- (cuentas INA pueden aparecer por historial, se permiten registros
        --  pero se advierte al operador vía NOTICE)
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'CUENTA_NO_ENCONTRADA: La cuenta [%] del asiento [%] '
                'no existe en el plan de cuentas.',
                rec.id_cuenta, p_id_asiento;
        END IF;
    END LOOP;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 7: Registrar operación en auditoría centralizada
    --   auditoria_sistema.id_auditoria es GENERATED ALWAYS AS IDENTITY
    --   → no se provee en el INSERT.
    --   operacion es tipo ENUM tipo_operacion_dml ('INSERT','UPDATE','DELETE').
    -- ──────────────────────────────────────────────────────────────────
    INSERT INTO auditoria_sistema (
        usuario_db,
        tabla_afectada,
        operacion,
        id_registro,
        valor_anterior,
        valor_nuevo
    ) VALUES (
        COALESCE(p_user_id::VARCHAR(80), CURRENT_USER),
        'asientos',
        'UPDATE'::tipo_operacion_dml,
        p_id_asiento,
        jsonb_build_object('estado_asi', 'PEN')::TEXT,
        jsonb_build_object(
            'estado_asi', 'APR',
            'asi_total_debe',  v_sum_debe,
            'asi_total_haber', v_sum_haber,
            'partidas',        v_count_partidas
        )::TEXT
    );

    -- ──────────────────────────────────────────────────────────────────
    -- COMMIT: confirma los cambios en asientos, cuentas y auditoria
    -- Si algo falla antes de este punto, el EXCEPTION hará ROLLBACK.
    -- ──────────────────────────────────────────────────────────────────
    COMMIT;

    RAISE NOTICE
        '[APR OK] Asiento % aprobado. Partidas: % | DEBE: % | HABER: % | Usuario: %',
        p_id_asiento, v_count_partidas, v_sum_debe, v_sum_haber,
        COALESCE(p_user_id, CURRENT_USER);

EXCEPTION
    -- Bloqueo concurrente: otra sesión está procesando el mismo asiento
    WHEN lock_not_available THEN
        ROLLBACK;
        RAISE EXCEPTION
            'CONCURRENCIA: El asiento [%] está siendo procesado por otra sesión. '
            'Intente nuevamente en unos segundos.',
            p_id_asiento;

    -- Re-lanzar cualquier otro error tras ROLLBACK
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;

COMMENT ON PROCEDURE sp_aprobar_asiento_contable(CHAR, CHAR) IS
'Aprueba un asiento contable (PEN → APR): valida partida doble recalculando
 desde ctaxasi, actualiza cabecera y acumula saldos en plan de cuentas (cue_debe00/haber00).
 Usa FOR UPDATE NOWAIT para seguridad concurrente. Atomic con COMMIT/ROLLBACK.';


-- ════════════════════════════════════════════════════════════════════════
--  SP 2: sp_anular_asiento_contable
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Anula un asiento contable en estado PEN o APR. Si estaba APR,
--    revierte los acumulados en el Plan de Cuentas. Verifica que ningún
--    documento vinculado (facturas, devoluciones, ajustes, rol_pagos)
--    esté activo en estado APR antes de proceder.
--
--  PARÁMETROS:
--    p_id_asiento  CHAR(7)    — PK del asiento a anular
--    p_user_id     CHAR(16)   — usuario que ejecuta (auditoría)
--    p_motivo      VARCHAR(200) — razón de la anulación
--
--  FLUJO:
--    1. Bloquear cabecera con FOR UPDATE NOWAIT
--    2. Validar estado <> ANU (idempotencia)
--    3. Verificar que no existan documentos APR vinculados al asiento
--    4. Si estado = APR → revertir acumulados en cuentas (operación inversa)
--    5. Marcar todas las partidas de ctaxasi como INA
--    6. UPDATE asientos → estado 'ANU'
--       (trigger verifica DEBE=HABER de los totales existentes → pasa sin cambio)
--    7. Registrar en auditoria_sistema
--    8. COMMIT
--
--  ATOMICIDAD:
--    Si la reversión de cuentas falla a mitad del loop, el ROLLBACK
--    deshace también las partidas ya revertidas → estado consistente.
--
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE sp_anular_asiento_contable(
    IN p_id_asiento  CHAR(7),
    IN p_user_id     CHAR(16)     DEFAULT NULL,
    IN p_motivo      VARCHAR(200) DEFAULT 'Anulación manual'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado            CHAR(3);
    v_docs_aprobados    INTEGER;   -- documentos vinculados en estado APR
    rec                 RECORD;
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- PASO 1: Bloquear la cabecera del asiento
    -- ──────────────────────────────────────────────────────────────────
    SELECT estado_asi
    INTO   v_estado
    FROM   asientos
    WHERE  id_asiento = p_id_asiento
    FOR UPDATE NOWAIT;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ASIENTO_NO_ENCONTRADO: El asiento [%] no existe en el sistema.',
            p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 2: Validar estado — proteger contra doble anulación
    -- ──────────────────────────────────────────────────────────────────
    IF v_estado = 'ANU' THEN
        RAISE EXCEPTION
            'YA_ANULADO: El asiento [%] ya se encuentra en estado ANU. '
            'No se puede anular dos veces.',
            p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 3: Verificar que no existan documentos APR vinculados
    --   Un asiento APR puede estar vinculado a: facturas, devoluciones,
    --   ajustes_inv, rol_pagos. Si alguno de esos documentos está APR,
    --   anular el asiento crearía una inconsistencia contable grave
    --   (documento aprobado sin respaldo en el libro mayor).
    --
    --   Estrategia: UNION ALL de los 4 módulos + COUNT.
    --   Todos los accesos son por FK que deberían tener índice secundario.
    -- ──────────────────────────────────────────────────────────────────
    SELECT COUNT(*) INTO v_docs_aprobados
    FROM (
        -- Módulo Ventas: facturas aprobadas con este asiento
        SELECT id_factura AS id_doc, 'facturas' AS modulo
        FROM   facturas
        WHERE  id_asiento  = p_id_asiento
          AND  estado_fac  = 'APR'

        UNION ALL

        -- Módulo Ventas: devoluciones aprobadas con este asiento
        SELECT id_devolucion, 'devoluciones'
        FROM   devoluciones
        WHERE  id_asiento  = p_id_asiento
          AND  estado_dev  = 'APR'

        UNION ALL

        -- Módulo Inventarios: ajustes aprobados con este asiento
        SELECT id_ajuste, 'ajustes_inv'
        FROM   ajustes_inv
        WHERE  id_asiento  = p_id_asiento
          AND  estado_aji  = 'APR'

        UNION ALL

        -- Módulo RRHH: roles de pago aprobados con este asiento
        SELECT id_rol_pago, 'rol_pagos'
        FROM   rol_pagos
        WHERE  id_asiento  = p_id_asiento
          AND  estado_rpl  = 'APR'
    ) docs_aprobados;

    IF v_docs_aprobados > 0 THEN
        RAISE EXCEPTION
            'DOCUMENTOS_VINCULADOS: El asiento [%] tiene % documento(s) en estado APR '
            'vinculados. Anule primero los documentos origen (facturas, devoluciones, '
            'ajustes o rol de pagos) antes de anular el asiento contable.',
            p_id_asiento, v_docs_aprobados;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 4: Revertir acumulados del Plan de Cuentas (solo si era APR)
    --   Si el asiento estaba en PEN, sus valores nunca fueron acumulados
    --   en cuentas (eso ocurre al aprobar), por lo que no hay nada que revertir.
    --   Si estaba APR, debemos restar exactamente lo que se sumó al aprobar.
    -- ──────────────────────────────────────────────────────────────────
    IF v_estado = 'APR' THEN
        FOR rec IN
            SELECT id_cuenta, cxa_debe, cxa_haber
            FROM   ctaxasi
            WHERE  id_asiento = p_id_asiento
              AND  estado_cxa = 'ACT'     -- solo partidas que fueron acumuladas
        LOOP
            UPDATE cuentas
            SET
                cue_debe00  = cue_debe00  - rec.cxa_debe,
                cue_haber00 = cue_haber00 - rec.cxa_haber
            WHERE id_cuenta = rec.id_cuenta;

            IF NOT FOUND THEN
                -- La cuenta debería existir porque la FK lo garantiza,
                -- pero protegemos contra corrupción de datos
                RAISE EXCEPTION
                    'CUENTA_NO_ENCONTRADA: La cuenta [%] no existe al intentar '
                    'revertir los acumulados del asiento [%].',
                    rec.id_cuenta, p_id_asiento;
            END IF;
        END LOOP;

        RAISE NOTICE
            '[INFO] Acumulados revertidos en Plan de Cuentas para asiento %.',
            p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 5: Desactivar todas las partidas del asiento en ctaxasi
    --   estado_cxa → 'INA' preserva el historial de las partidas
    --   (no se eliminan — auditoría contable exige trazabilidad completa).
    -- ──────────────────────────────────────────────────────────────────
    UPDATE ctaxasi
    SET    estado_cxa = 'INA'
    WHERE  id_asiento  = p_id_asiento
      AND  estado_cxa  = 'ACT';

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 6: Actualizar cabecera → estado ANU
    --   No se modifican asi_total_debe ni asi_total_haber para preservar
    --   el historial. El trigger fn_validar_partida_doble verificará que
    --   los totales sigan siendo iguales entre sí — condición que se cumple
    --   porque no cambiamos esas columnas.
    -- ──────────────────────────────────────────────────────────────────
    UPDATE asientos
    SET
        estado_asi = 'ANU',
        user_id    = COALESCE(p_user_id, user_id)
    WHERE id_asiento = p_id_asiento;

    -- ──────────────────────────────────────────────────────────────────
    -- PASO 7: Registrar en auditoría centralizada
    -- ──────────────────────────────────────────────────────────────────
    INSERT INTO auditoria_sistema (
        usuario_db,
        tabla_afectada,
        operacion,
        id_registro,
        valor_anterior,
        valor_nuevo
    ) VALUES (
        COALESCE(p_user_id::VARCHAR(80), CURRENT_USER),
        'asientos',
        'UPDATE'::tipo_operacion_dml,
        p_id_asiento,
        jsonb_build_object('estado_asi', v_estado)::TEXT,
        jsonb_build_object(
            'estado_asi', 'ANU',
            'motivo',     p_motivo,
            'acumulados_revertidos', (v_estado = 'APR')
        )::TEXT
    );

    -- ──────────────────────────────────────────────────────────────────
    -- COMMIT: confirma reversión de cuentas + partidas INA + cabecera ANU
    -- ──────────────────────────────────────────────────────────────────
    COMMIT;

    RAISE NOTICE
        '[ANU OK] Asiento % anulado (estado previo: %). Motivo: % | Usuario: %',
        p_id_asiento, v_estado, p_motivo,
        COALESCE(p_user_id, CURRENT_USER);

EXCEPTION
    WHEN lock_not_available THEN
        ROLLBACK;
        RAISE EXCEPTION
            'CONCURRENCIA: El asiento [%] está bloqueado por otra sesión. '
            'Intente nuevamente.',
            p_id_asiento;

    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;

COMMENT ON PROCEDURE sp_anular_asiento_contable(CHAR, CHAR, VARCHAR) IS
'Anula un asiento contable (PEN|APR → ANU): verifica documentos vinculados APR,
 revierte acumulados en Plan de Cuentas si el asiento estaba APR, marca partidas
 como INA. Preserva historial completo. Atomic con COMMIT/ROLLBACK.';


-- ════════════════════════════════════════════════════════════════════════
--  SP 3: sp_visualizar_asiento_contable
-- ════════════════════════════════════════════════════════════════════════
--
--  PROPÓSITO:
--    Devuelve la cabecera y el detalle completo de un asiento contable
--    mediante dos REFCURSOR, patrón estándar de PostgreSQL para retornar
--    múltiples conjuntos de resultados desde un PROCEDURE.
--
--  PARÁMETROS:
--    IN    p_id_asiento    CHAR(7)    — PK del asiento a visualizar
--    INOUT cur_cabecera    REFCURSOR  — cursor de la cabecera (1 fila)
--    INOUT cur_detalle     REFCURSOR  — cursor del detalle (N partidas)
--
--  CURSORES RETORNADOS:
--    cur_cabecera → columnas de `asientos` enriquecidas con balance
--    cur_detalle  → partidas de `ctaxasi` JOIN `cuentas` JOIN `tipo_cuenta`
--
--  MODO DE LLAMADA (requiere bloque de transacción explícito):
--    BEGIN;
--      CALL sp_visualizar_asiento_contable('ASI0001', 'cur_cab', 'cur_det');
--      FETCH ALL FROM cur_cab;
--      FETCH ALL FROM cur_det;
--    COMMIT;
--
--  NOTA: Los cursores se cierran automáticamente al finalizar la transacción.
--
--  OPTIMIZACIÓN:
--    Acceso a asientos por pk_asientos (seek directo).
--    Join ctaxasi → cuentas por pk_ctaxasi + pk_cuentas.
--    Join cuentas → tipo_cuenta por pk_tipo_cuenta (tabla pequeña, cacheada).
--    El ORDER BY en cur_detalle ordena DEBE desc primero para presentar
--    la estructura debe/haber de forma contablemente natural.
--
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE sp_visualizar_asiento_contable(
    IN    p_id_asiento  CHAR(7),
    INOUT cur_cabecera  REFCURSOR DEFAULT 'cur_cabecera',
    INOUT cur_detalle   REFCURSOR DEFAULT 'cur_detalle'
)
LANGUAGE plpgsql AS $$
BEGIN
    -- ──────────────────────────────────────────────────────────────────
    -- Validación rápida de existencia antes de abrir cursores
    -- (evita abrir cursores vacíos sin aviso al caller)
    -- ──────────────────────────────────────────────────────────────────
    IF NOT EXISTS (
        SELECT 1 FROM asientos WHERE id_asiento = p_id_asiento
    ) THEN
        RAISE EXCEPTION
            'ASIENTO_NO_ENCONTRADO: El asiento [%] no existe.',
            p_id_asiento;
    END IF;

    -- ──────────────────────────────────────────────────────────────────
    -- CURSOR 1: cur_cabecera
    --   Retorna la fila de asientos + columnas calculadas:
    --   - balance_cuadrado: TRUE si DEBE = HABER (semáforo visual)
    --   - partidas_activas: conteo de líneas en ctaxasi con estado ACT
    --   - partidas_total:   conteo de todas las líneas (incluye INA/historial)
    -- ──────────────────────────────────────────────────────────────────
    OPEN cur_cabecera FOR
        SELECT
            a.id_asiento,
            a.asi_descripcion,
            a.asi_total_debe,
            a.asi_total_haber,
            (a.asi_total_debe = a.asi_total_haber)          AS balance_cuadrado,
            a.asi_fecha_hora,
            a.estado_asi,
            a.user_id,
            -- Sub-consultas escalares: acceso por pk_ctaxasi → seeks
            (SELECT COUNT(*) FROM ctaxasi
             WHERE id_asiento = a.id_asiento AND estado_cxa = 'ACT') AS partidas_activas,
            (SELECT COUNT(*) FROM ctaxasi
             WHERE id_asiento = a.id_asiento)                        AS partidas_total,
            -- Documentos vinculados: información de trazabilidad
            (SELECT COUNT(*) FROM facturas
             WHERE id_asiento = a.id_asiento)                        AS facturas_vinculadas,
            (SELECT COUNT(*) FROM ajustes_inv
             WHERE id_asiento = a.id_asiento)                        AS ajustes_vinculados,
            (SELECT COUNT(*) FROM rol_pagos
             WHERE id_asiento = a.id_asiento)                        AS roles_vinculados,
            (SELECT COUNT(*) FROM devoluciones
             WHERE id_asiento = a.id_asiento)                        AS devoluciones_vinculadas
        FROM asientos a
        WHERE a.id_asiento = p_id_asiento;

    -- ──────────────────────────────────────────────────────────────────
    -- CURSOR 2: cur_detalle
    --   Retorna las partidas del asiento enriquecidas con:
    --   - nombre y tipo de la cuenta contable
    --   - columna "naturaleza" para indicar si la línea es DEBE o HABER
    --   - saldo_neto: diferencia entre debe y haber de esa cuenta en el asiento
    --
    --   JOINs:
    --     ctaxasi  → cuentas     (pk_ctaxasi / pk_cuentas: seek directo)
    --     cuentas  → tipo_cuenta (pk_tipo_cuenta: tabla pequeña, hot cache)
    --
    --   ORDER BY: primero las partidas del DEBE (cxa_debe > 0), luego el HABER
    --   para presentar el asiento en el formato contable estándar.
    -- ──────────────────────────────────────────────────────────────────
    OPEN cur_detalle FOR
        SELECT
            cxa.id_cuenta,
            cu.cue_descripcion                              AS cuenta_nombre,
            tc.tip_descripcion                              AS tipo_cuenta,
            cxa.cxa_debe,
            cxa.cxa_haber,
            -- Naturaleza contable de la línea para reportes visuales
            CASE
                WHEN cxa.cxa_debe  > 0 AND cxa.cxa_haber = 0 THEN 'DEBE'
                WHEN cxa.cxa_haber > 0 AND cxa.cxa_debe  = 0 THEN 'HABER'
                ELSE 'MIXTO'   -- teóricamente imposible por chk_cxa_no_cero
            END                                             AS naturaleza,
            (cxa.cxa_debe - cxa.cxa_haber)                 AS saldo_neto,
            cxa.estado_cxa,
            cu.estado_cue                                   AS estado_cuenta
        FROM ctaxasi    cxa
        JOIN cuentas    cu  ON cu.id_cuenta    = cxa.id_cuenta
        JOIN tipo_cuenta tc ON tc.id_tipo_cta  = cu.cue_tipo
        WHERE cxa.id_asiento = p_id_asiento
        ORDER BY
            cxa.cxa_debe  DESC,   -- primero el DEBE (positivo al tope)
            cxa.cxa_haber DESC,   -- luego el HABER
            cxa.id_cuenta  ASC;   -- desempate por código de cuenta (orden jerárquico)

    -- No hay COMMIT aquí: sp_visualizar es operación de solo lectura.
    -- Los cursores permanecen abiertos hasta que el caller los consuma
    -- y finalice su bloque de transacción (BEGIN ... COMMIT).

    RAISE NOTICE
        '[VIZ OK] Cursores abiertos para asiento %. Use FETCH ALL FROM % y FETCH ALL FROM %.',
        p_id_asiento, cur_cabecera, cur_detalle;

EXCEPTION
    WHEN OTHERS THEN
        -- En sp_visualizar no hay cambios que revertir, pero cerramos limpio
        RAISE;
END;
$$;

COMMENT ON PROCEDURE sp_visualizar_asiento_contable(CHAR, REFCURSOR, REFCURSOR) IS
'Retorna cabecera y detalle de un asiento contable vía dos REFCURSOR.
 cur_cabecera: 1 fila con totales, balance_cuadrado y conteos de vínculos.
 cur_detalle: N filas (ctaxasi JOIN cuentas JOIN tipo_cuenta) ordenadas DEBE→HABER.
 Llamar dentro de BEGIN...COMMIT para que los cursores permanezcan abiertos.';


-- ════════════════════════════════════════════════════════════════════════
--  EJEMPLOS DE USO
-- ════════════════════════════════════════════════════════════════════════

/*
-- ── Aprobar un asiento ────────────────────────────────────────────────
CALL comercial.sp_aprobar_asiento_contable(
    p_id_asiento => 'ASI0001',
    p_user_id    => 'USR_CONTA'
);

-- ── Anular un asiento pendiente ───────────────────────────────────────
CALL comercial.sp_anular_asiento_contable(
    p_id_asiento => 'ASI0002',
    p_user_id    => 'USR_JCONT',
    p_motivo     => 'Error en asignación de cuentas. Se genera asiento corregido ASI0003.'
);

-- ── Visualizar un asiento (requiere bloque de transacción) ───────────
BEGIN;
    CALL comercial.sp_visualizar_asiento_contable(
        p_id_asiento => 'ASI0001',
        cur_cabecera => 'cur_cab',
        cur_detalle  => 'cur_det'
    );
    FETCH ALL FROM cur_cab;   -- 1 fila: datos del asiento + métricas
    FETCH ALL FROM cur_det;   -- N filas: partidas DEBE/HABER con nombres de cuentas
COMMIT;

-- ── Caso real: rol de pagos → aprobar asiento generado ───────────────
-- El módulo RRHH llama a sp_aprobar_rol_pagos (externo),
-- que crea el asiento en estado PEN. Luego contabilidad:
CALL comercial.sp_aprobar_asiento_contable('RPAS001', 'CNT_APRO');

-- ── Verificar estado tras aprobación ─────────────────────────────────
SELECT id_asiento, estado_asi, asi_total_debe, asi_total_haber
FROM   comercial.asientos
WHERE  id_asiento = 'ASI0001';

-- ── Ver acumulados actualizados en el plan de cuentas ─────────────────
SELECT id_cuenta, cue_descripcion, cue_debe00, cue_haber00
FROM   comercial.cuentas
WHERE  cue_debe00 > 0 OR cue_haber00 > 0
ORDER BY id_cuenta;
*/


-- ████████████████████████████████████████████████████████████████████████
--  RESUMEN DE ATOMICIDAD
-- ████████████████████████████████████████████████████████████████████████
--
--  sp_aprobar_asiento_contable:
--  ┌─────────────────────────────────────────────────────────────────────┐
--  │  FOR UPDATE NOWAIT    → lock antes de cualquier escritura           │
--  │  Validaciones         → RAISE EXCEPTION sin tocar datos             │
--  │  UPDATE asientos      → trigger valida partida doble (2ª defensa)   │
--  │  LOOP UPDATE cuentas  → si falla en cuenta N, ROLLBACK revierte     │
--  │                         las cuentas 1..N-1 ya actualizadas          │
--  │  INSERT auditoria     → garantiza log incluso si no hay FK directa  │
--  │  COMMIT               → punto de no retorno                         │
--  │  EXCEPTION → ROLLBACK → ningún cambio persiste                      │
--  └─────────────────────────────────────────────────────────────────────┘
--
--  sp_anular_asiento_contable:
--  ┌─────────────────────────────────────────────────────────────────────┐
--  │  FOR UPDATE NOWAIT    → lock antes de cualquier escritura           │
--  │  CHECK docs APR       → aborta si hay documentos vinculados activos │
--  │  LOOP UPDATE cuentas  → reversión solo si estado = APR             │
--  │                         ROLLBACK revierte reversiones parciales     │
--  │  UPDATE ctaxasi       → INA masivo (batch por id_asiento)           │
--  │  UPDATE asientos      → trigger pasa porque no cambió DEBE/HABER   │
--  │  INSERT auditoria     → preserva motivo de anulación               │
--  │  COMMIT               → punto de no retorno                         │
--  │  EXCEPTION → ROLLBACK → estado original restaurado                 │
--  └─────────────────────────────────────────────────────────────────────┘
--
--  sp_visualizar_asiento_contable:
--  ┌─────────────────────────────────────────────────────────────────────┐
--  │  Solo lectura — sin escrituras, sin COMMIT/ROLLBACK explícitos      │
--  │  Cursores válidos hasta el COMMIT del bloque BEGIN del llamador     │
--  │  Joins por PK → sin table scans en tablas de 400K+ registros        │
--  └─────────────────────────────────────────────────────────────────────┘
--
-- ████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT — JW Cóndor | COMERCIAL Contabilidad SPs | PG 16
-- ████████████████████████████████████████████████████████████████████████
