-- =====================================================================
-- 02_bronce_procedimiento.sql
-- CAPA BRONCE - Proceso de extracción y carga (la "E" y la "L" del ETL)
--
-- Crea el procedimiento bronce.sp_cargar_bronce(), que:
--   1. Abre un lote en bronce.control_lote
--   2. Recorre bronce.config_extraccion y por cada tabla:
--        - completa    -> TRUNCATE + INSERT de toda la tabla
--        - incremental -> INSERT solo de llave > marca de agua (máx. llave ya cargada)
--   3. Registra filas, marcas de agua y tiempo en bronce.control_carga
--   4. Cierra el lote
-- Todo corre en UNA transacción: si algo falla, no queda un lote a medias.
-- =====================================================================

CREATE OR REPLACE PROCEDURE bronce.sp_cargar_bronce()
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote     INT;
    t          RECORD;
    v_ini      BIGINT;
    v_fin      BIGINT;
    v_origen   BIGINT;
    v_filas    BIGINT;
    v_t0       TIMESTAMPTZ;
BEGIN
    INSERT INTO bronce.control_lote DEFAULT VALUES RETURNING lote_id INTO v_lote;
    RAISE NOTICE 'Lote % iniciado', v_lote;

    FOR t IN SELECT * FROM bronce.config_extraccion WHERE activa ORDER BY orden LOOP
        v_t0 := clock_timestamp();

        IF t.modo_carga = 'completa' THEN
            v_ini := NULL;
            EXECUTE format('TRUNCATE bronce.%I', t.tabla);
            EXECUTE format(
                'INSERT INTO bronce.%1$I
                 SELECT s.*, now(), $1, %2$L FROM public.%1$I s',
                t.tabla, 'delivery_oltp.public.' || t.tabla)
            USING v_lote;
        ELSE
            -- marca de agua: la llave más alta que ya está en bronce
            EXECUTE format('SELECT coalesce(max(%I), 0) FROM bronce.%I', t.llave, t.tabla)
            INTO v_ini;
            EXECUTE format(
                'INSERT INTO bronce.%1$I
                 SELECT s.*, now(), $1, %3$L FROM public.%1$I s
                 WHERE s.%2$I > $2',
                t.tabla, t.llave, 'delivery_oltp.public.' || t.tabla)
            USING v_lote, v_ini;
        END IF;
        GET DIAGNOSTICS v_filas = ROW_COUNT;

        EXECUTE format('SELECT count(*), max(%I) FROM public.%I', t.llave, t.tabla)
        INTO v_origen, v_fin;

        INSERT INTO bronce.control_carga
        VALUES (v_lote, t.tabla, t.modo_carga, v_ini, v_fin, v_origen, v_filas,
                round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2));

        RAISE NOTICE '  % (%): % filas', t.tabla, t.modo_carga, v_filas;
    END LOOP;

    UPDATE bronce.control_lote
       SET fecha_fin = clock_timestamp(), estado = 'ok'
     WHERE lote_id = v_lote;
    RAISE NOTICE 'Lote % terminado', v_lote;
END $$;

COMMENT ON PROCEDURE bronce.sp_cargar_bronce() IS
  'Extrae del OLTP (public) a la capa bronce. Completa para maestros, incremental por marca de agua para transacciones.';
