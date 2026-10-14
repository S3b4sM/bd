-- =====================================================================
-- 02_plata_procedimiento.sql
-- CAPA PLATA - Proceso de transformación (la "T" del ETL)
--
-- Crea el procedimiento plata.sp_cargar_plata(), que lee de BRONCE y:
--   0. Abre un lote y calcula el límite de atípicos (IQR)
--   1. Mide cuántos registros afecta cada regla (plata.control_calidad)
--   2. Limpia, estandariza y anonimiza catálogos y maestros
--   3. Valida reglas de negocio e integridad: lo que falla va a CUARENTENA
--   4. Carga las transacciones que pasaron, con sus campos derivados
--   5. Cierra el lote
-- Modo de carga: recarga completa (TRUNCATE + INSERT) desde bronce.
-- Todo corre en UNA transacción: si algo falla, plata queda como estaba.
-- No modifica public ni bronce (solo los lee).
-- =====================================================================

CREATE OR REPLACE PROCEDURE plata.sp_cargar_plata()
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote   INT;
    v_t0     TIMESTAMPTZ;
    v_q1     NUMERIC;
    v_q3     NUMERIC;
    v_lim    NUMERIC;
    -- Emojis: rangos Unicode de pictogramas, símbolos y selector de variación
    c_emoji  CONSTANT TEXT := '[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0000FE0F\U0000200D]';
    -- Patrón de email válido
    c_email  CONSTANT TEXT := '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$';
BEGIN
    -- =================================================================
    -- 0. LOTE + LÍMITE DE ATÍPICOS (DER-02)
    -- =================================================================
    SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY m),
           percentile_cont(0.75) WITHIN GROUP (ORDER BY m)
      INTO v_q1, v_q3
    FROM (SELECT extract(epoch FROM fecha_hora_entrega - fecha_hora_pedido) / 60 AS m
          FROM bronce.pedido WHERE estado = 'entregado') t;
    v_lim := v_q3 + 1.5 * (v_q3 - v_q1);

    INSERT INTO plata.control_lote (lote_bronce, q1_entrega, q3_entrega, limite_atipico)
    SELECT max(lote_id), round(v_q1, 1), round(v_q3, 1), round(v_lim, 1)
    FROM bronce.control_lote WHERE estado = 'ok'
    RETURNING lote_id INTO v_lote;
    RAISE NOTICE 'Lote plata % iniciado (Q1 = %, Q3 = %, límite atípico = % min)',
                 v_lote, round(v_q1, 1), round(v_q3, 1), round(v_lim, 1);

    TRUNCATE plata.zona, plata.categoria_cocina, plata.metodo_pago, plata.promocion,
             plata.cliente, plata.restaurante, plata.producto, plata.repartidor,
             plata.pedido, plata.detalle_pedido, plata.pago, plata.calificacion;

    DROP TABLE IF EXISTS tmp_rechazo;
    CREATE TEMP TABLE tmp_rechazo (tabla VARCHAR(40), id BIGINT, regla VARCHAR(10), detalle TEXT) ON COMMIT DROP;

    -- =================================================================
    -- 1. MEDICIÓN DE REGLAS DE CALIDAD, SEGURIDAD, DERIVADOS Y DOMINIO
    -- =================================================================
    v_t0 := clock_timestamp();

    -- Cliente
    INSERT INTO plata.control_calidad (lote_id, codigo_regla, filas_evaluadas, filas_afectadas)
    SELECT v_lote, r.regla, r.evaluadas, r.afectadas
    FROM (
        SELECT count(*) AS n,
               count(*) FILTER (WHERE nombre <> initcap(regexp_replace(btrim(nombre), '\s+', ' ', 'g'))) AS cal01,
               count(*) FILTER (WHERE genero IS NULL) AS cal02,
               count(*) FILTER (WHERE fecha_nacimiento IS NULL
                                   OR date_part('year', age(current_date, fecha_nacimiento)) NOT BETWEEN 14 AND 100) AS cal03,
               count(*) FILTER (WHERE email <> lower(btrim(email)) OR lower(btrim(email)) !~ c_email) AS seg01,
               count(*) - count(DISTINCT lower(btrim(email))) AS seg02,
               count(*) FILTER (WHERE telefono IS NOT NULL AND telefono !~ '^3[0-9]{9}$') AS seg03,
               count(*) FILTER (WHERE telefono IS NULL) AS seg04,
               count(*) FILTER (WHERE direccion IS NOT NULL) AS seg05
        FROM bronce.cliente
    ) c,
    LATERAL (VALUES ('CAL-01', c.n, c.cal01), ('CAL-02', c.n, c.cal02), ('CAL-03', c.n, c.cal03),
                    ('SEG-01', c.n, c.seg01), ('SEG-02', c.n, c.seg02), ('SEG-03', c.n, c.seg03),
                    ('SEG-04', c.n, c.seg04)) r(regla, evaluadas, afectadas);

    INSERT INTO plata.control_calidad
    SELECT v_lote, 'SEG-05',
           (SELECT count(*) FROM bronce.cliente) + (SELECT count(*) FROM bronce.restaurante),
           (SELECT count(direccion) FROM bronce.cliente) + (SELECT count(direccion) FROM bronce.restaurante);

    -- Calificación
    INSERT INTO plata.control_calidad (lote_id, codigo_regla, filas_evaluadas, filas_afectadas)
    SELECT v_lote, r.regla, r.evaluadas, r.afectadas
    FROM (
        SELECT count(*) AS n,
               count(*) FILTER (WHERE comentario <> btrim(comentario)) AS cal04,
               count(*) FILTER (WHERE comentario ~ c_emoji) AS cal05,
               count(*) FILTER (WHERE comentario IS NULL OR btrim(comentario) = '') AS cal06
        FROM bronce.calificacion
    ) c,
    LATERAL (VALUES ('CAL-04', c.n, c.cal04), ('CAL-05', c.n, c.cal05), ('CAL-06', c.n, c.cal06)) r(regla, evaluadas, afectadas);

    -- Pedido
    INSERT INTO plata.control_calidad (lote_id, codigo_regla, filas_evaluadas, filas_afectadas)
    SELECT v_lote, r.regla, r.evaluadas, r.afectadas
    FROM (
        SELECT count(*) AS n,
               count(*) FILTER (WHERE estado = 'entregado') AS entregados,
               count(*) FILTER (WHERE estado = 'entregado'
                                  AND extract(epoch FROM fecha_hora_entrega - fecha_hora_pedido) / 60 > v_lim) AS der02,
               count(*) FILTER (WHERE estado IN ('en camino','en preparacion')) AS dom01,
               count(*) FILTER (WHERE id_repartidor IS NULL OR id_promocion IS NULL) AS int03
        FROM bronce.pedido
    ) p,
    LATERAL (VALUES ('DER-01', p.n, p.entregados), ('DER-02', p.entregados, p.der02),
                    ('DOM-01', p.n, p.dom01), ('INT-03', p.n, p.int03)) r(regla, evaluadas, afectadas);

    -- Pago, método de pago y precio histórico
    INSERT INTO plata.control_calidad
    SELECT v_lote, 'DER-03', count(*), count(*) FILTER (WHERE estado <> 'aprobado') FROM bronce.pago;
    INSERT INTO plata.control_calidad
    SELECT v_lote, 'DER-04', count(*), count(*) FROM bronce.metodo_pago;
    INSERT INTO plata.control_calidad
    SELECT v_lote, 'DER-05', count(*), count(*) FILTER (WHERE d.precio_unitario <> pr.precio)
    FROM bronce.detalle_pedido d JOIN bronce.producto pr USING (id_producto);

    RAISE NOTICE '  1. Medición de reglas: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    -- =================================================================
    -- 2. CATÁLOGOS Y MAESTROS (limpieza + estandarización + anonimización)
    -- =================================================================
    v_t0 := clock_timestamp();

    INSERT INTO plata.zona (id_zona, ciudad, nombre_zona, codigo_postal, tarifa_base_envio, _lote_id)
    SELECT id_zona, initcap(btrim(ciudad)), btrim(nombre_zona), btrim(codigo_postal), tarifa_base_envio, v_lote
    FROM bronce.zona;

    INSERT INTO plata.categoria_cocina (id_categoria, nombre, _lote_id)
    SELECT id_categoria, btrim(nombre), v_lote FROM bronce.categoria_cocina;

    INSERT INTO plata.metodo_pago (id_metodo, nombre, tipo_metodo, _lote_id)
    SELECT id_metodo, btrim(nombre),
           CASE WHEN nombre ILIKE 'tarjeta%'         THEN 'Tarjeta'                 -- DER-04
                WHEN nombre ILIKE 'efectivo%'        THEN 'Efectivo'
                WHEN nombre IN ('Nequi','Daviplata') THEN 'Billetera digital'
                WHEN nombre = 'PSE'                  THEN 'Transferencia'
                ELSE 'Otro' END,
           v_lote
    FROM bronce.metodo_pago;

    INSERT INTO plata.promocion (id_promocion, codigo, tipo_descuento, valor, fecha_inicio, fecha_fin, duracion_dias, _lote_id)
    SELECT id_promocion, upper(btrim(codigo)), lower(btrim(tipo_descuento)), valor,
           fecha_inicio, fecha_fin, fecha_fin - fecha_inicio + 1, v_lote
    FROM bronce.promocion;

    -- SEG-02: emails repetidos -> se conserva el cliente más antiguo, el resto a cuarentena
    INSERT INTO tmp_rechazo
    SELECT 'cliente', id_cliente, 'SEG-02', 'email repetido (se conservó el cliente más antiguo)'
    FROM (SELECT id_cliente,
                 row_number() OVER (PARTITION BY lower(btrim(email)) ORDER BY fecha_registro, id_cliente) AS rn
          FROM bronce.cliente) d
    WHERE rn > 1;

    INSERT INTO plata.cliente (id_cliente, nombre, email_hash, dominio_email, email_valido,
                               telefono_hash, telefono_valido, fecha_nacimiento, edad, rango_edad,
                               genero, genero_desc, id_zona, fecha_registro, _lote_id)
    SELECT c.id_cliente,
           initcap(regexp_replace(btrim(c.nombre), '\s+', ' ', 'g')),                 -- CAL-01
           md5(e.email),                                                             -- SEG-01
           split_part(e.email, '@', 2),
           e.email ~ c_email,
           CASE WHEN t.tel ~ '^3[0-9]{9}$' THEN md5(t.tel) END,                       -- SEG-03
           coalesce(t.tel ~ '^3[0-9]{9}$', false),                                   -- SEG-03 / SEG-04
           CASE WHEN a.edad BETWEEN 14 AND 100 THEN c.fecha_nacimiento END,
           CASE WHEN a.edad BETWEEN 14 AND 100 THEN a.edad END,                      -- CAL-03
           CASE WHEN a.edad IS NULL OR a.edad NOT BETWEEN 14 AND 100 THEN 'Sin dato'
                WHEN a.edad < 18 THEN '14-17'
                WHEN a.edad < 25 THEN '18-24'
                WHEN a.edad < 35 THEN '25-34'
                WHEN a.edad < 45 THEN '35-44'
                WHEN a.edad < 55 THEN '45-54'
                WHEN a.edad < 65 THEN '55-64'
                ELSE '65+' END,
           coalesce(upper(c.genero), 'N'),                                           -- CAL-02
           CASE upper(c.genero) WHEN 'F' THEN 'Femenino' WHEN 'M' THEN 'Masculino'
                                WHEN 'O' THEN 'Otro' ELSE 'No informado' END,
           c.id_zona, c.fecha_registro, v_lote
           -- SEG-05: la dirección NO se copia
    FROM bronce.cliente c
    CROSS JOIN LATERAL (SELECT lower(btrim(c.email)) AS email) e
    CROSS JOIN LATERAL (                                                            -- 10 dígitos: quita +57, espacios y guiones
        SELECT CASE WHEN d ~ '^57[0-9]{10}$' THEN substr(d, 3) ELSE d END AS tel
        FROM (SELECT regexp_replace(c.telefono, '\D', '', 'g') AS d) x) t
    CROSS JOIN LATERAL (SELECT date_part('year', age(current_date, c.fecha_nacimiento))::smallint AS edad) a
    WHERE NOT EXISTS (SELECT 1 FROM tmp_rechazo r WHERE r.tabla = 'cliente' AND r.id = c.id_cliente);

    INSERT INTO plata.restaurante (id_restaurante, nombre, id_categoria, id_zona, fecha_alta, estado, _lote_id)
    SELECT id_restaurante, regexp_replace(btrim(nombre), '\s+', ' ', 'g'), id_categoria, id_zona,
           fecha_alta, lower(btrim(estado)), v_lote                                  -- SEG-05: sin dirección
    FROM bronce.restaurante;

    INSERT INTO plata.producto (id_producto, id_restaurante, nombre, tipo_producto, precio_actual, activo, _lote_id)
    SELECT id_producto, id_restaurante, regexp_replace(btrim(nombre), '\s+', ' ', 'g'),
           lower(btrim(tipo_producto)), precio, activo, v_lote
    FROM bronce.producto;

    INSERT INTO plata.repartidor (id_repartidor, nombre, tipo_vehiculo, id_zona, fecha_ingreso, estado, _lote_id)
    SELECT id_repartidor, initcap(regexp_replace(btrim(nombre), '\s+', ' ', 'g')), lower(btrim(tipo_vehiculo)),
           id_zona, fecha_ingreso, lower(btrim(estado)), v_lote
    FROM bronce.repartidor;

    ANALYZE plata.cliente; ANALYZE plata.restaurante; ANALYZE plata.producto;
    ANALYZE plata.repartidor; ANALYZE plata.promocion; ANALYZE plata.metodo_pago;
    RAISE NOTICE '  2. Catálogos y maestros: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    -- =================================================================
    -- 3. REGLAS DE NEGOCIO E INTEGRIDAD -> tmp_rechazo -> cuarentena
    -- =================================================================
    v_t0 := clock_timestamp();

    -- NEG-01: total = subtotal + envío - descuento
    INSERT INTO tmp_rechazo
    SELECT 'pedido', id_pedido, 'NEG-01', format('total %s <> %s', total, subtotal + costo_envio - descuento)
    FROM bronce.pedido WHERE total <> subtotal + costo_envio - descuento;

    -- NEG-02: subtotal = suma del detalle
    INSERT INTO tmp_rechazo
    SELECT 'pedido', p.id_pedido, 'NEG-02', format('subtotal %s <> detalle %s', p.subtotal, coalesce(d.s, 0))
    FROM bronce.pedido p
    LEFT JOIN (SELECT id_pedido, sum(subtotal_linea) s FROM bronce.detalle_pedido GROUP BY id_pedido) d USING (id_pedido)
    WHERE p.subtotal <> coalesce(d.s, 0);

    -- NEG-03: cliente, restaurante y repartidor en la misma zona
    INSERT INTO tmp_rechazo
    SELECT 'pedido', p.id_pedido, 'NEG-03',
           format('zona cliente %s, restaurante %s, repartidor %s', c.id_zona, r.id_zona, rp.id_zona)
    FROM bronce.pedido p
    JOIN plata.cliente c       USING (id_cliente)
    JOIN plata.restaurante r   USING (id_restaurante)
    LEFT JOIN plata.repartidor rp USING (id_repartidor)
    WHERE c.id_zona <> r.id_zona OR rp.id_zona <> r.id_zona;

    -- NEG-04: coherencia estado / fecha de entrega
    INSERT INTO tmp_rechazo
    SELECT 'pedido', id_pedido, 'NEG-04', format('estado %s, entrega %s', estado, fecha_hora_entrega)
    FROM bronce.pedido
    WHERE (estado = 'entregado' AND (fecha_hora_entrega IS NULL OR fecha_hora_entrega <= fecha_hora_pedido))
       OR (estado <> 'entregado' AND fecha_hora_entrega IS NOT NULL);

    -- NEG-05: promoción dentro de vigencia
    INSERT INTO tmp_rechazo
    SELECT 'pedido', p.id_pedido, 'NEG-05',
           format('pedido %s fuera de %s a %s', p.fecha_hora_pedido::date, pm.fecha_inicio, pm.fecha_fin)
    FROM bronce.pedido p JOIN plata.promocion pm USING (id_promocion)
    WHERE p.fecha_hora_pedido::date NOT BETWEEN pm.fecha_inicio AND pm.fecha_fin;

    -- NEG-06: pedido no anterior al registro / alta / ingreso
    INSERT INTO tmp_rechazo
    SELECT 'pedido', p.id_pedido, 'NEG-06', 'pedido anterior al registro del cliente o alta del restaurante/repartidor'
    FROM bronce.pedido p
    JOIN plata.cliente c       USING (id_cliente)
    JOIN plata.restaurante r   USING (id_restaurante)
    LEFT JOIN plata.repartidor rp USING (id_repartidor)
    WHERE p.fecha_hora_pedido < c.fecha_registro
       OR p.fecha_hora_pedido::date < r.fecha_alta
       OR p.fecha_hora_pedido::date < rp.fecha_ingreso;

    -- NEG-07: el producto debe ser del restaurante del pedido
    INSERT INTO tmp_rechazo
    SELECT DISTINCT 'pedido', d.id_pedido, 'NEG-07', 'detalle con producto de otro restaurante'
    FROM bronce.detalle_pedido d
    JOIN bronce.pedido p    USING (id_pedido)
    JOIN plata.producto pr  USING (id_producto)
    WHERE pr.id_restaurante <> p.id_restaurante;

    -- NEG-08: calificación solo de pedidos entregados y después de la entrega
    INSERT INTO tmp_rechazo
    SELECT 'calificacion', c.id_calificacion, 'NEG-08', format('pedido %s, estado %s', c.id_pedido, p.estado)
    FROM bronce.calificacion c JOIN bronce.pedido p USING (id_pedido)
    WHERE p.estado <> 'entregado' OR c.fecha <= p.fecha_hora_entrega;

    -- NEG-09: validez de montos, cantidades y puntajes
    INSERT INTO tmp_rechazo
    SELECT 'pedido', id_pedido, 'NEG-09', 'monto negativo'
    FROM bronce.pedido WHERE subtotal < 0 OR costo_envio < 0 OR descuento < 0 OR total < 0
    UNION ALL
    SELECT 'detalle_pedido', id_detalle, 'NEG-09', 'cantidad o precio <= 0, o subtotal_linea <> cantidad * precio'
    FROM bronce.detalle_pedido
    WHERE cantidad <= 0 OR precio_unitario <= 0 OR subtotal_linea <> cantidad * precio_unitario
    UNION ALL
    SELECT 'pago', id_pago, 'NEG-09', 'monto negativo'
    FROM bronce.pago WHERE monto < 0
    UNION ALL
    SELECT 'calificacion', id_calificacion, 'NEG-09', 'puntaje fuera de 1-5'
    FROM bronce.calificacion
    WHERE puntaje_restaurante NOT BETWEEN 1 AND 5 OR puntaje_repartidor NOT BETWEEN 1 AND 5;

    -- INT-01: llaves foráneas del pedido (incluye clientes enviados a cuarentena por SEG-02)
    INSERT INTO tmp_rechazo
    SELECT 'pedido', p.id_pedido, 'INT-01', 'cliente/restaurante/repartidor/promoción inexistente'
    FROM bronce.pedido p
    WHERE NOT EXISTS (SELECT 1 FROM plata.cliente c     WHERE c.id_cliente     = p.id_cliente)
       OR NOT EXISTS (SELECT 1 FROM plata.restaurante r WHERE r.id_restaurante = p.id_restaurante)
       OR (p.id_repartidor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM plata.repartidor r WHERE r.id_repartidor = p.id_repartidor))
       OR (p.id_promocion  IS NOT NULL AND NOT EXISTS (SELECT 1 FROM plata.promocion  r WHERE r.id_promocion  = p.id_promocion));

    -- INT-02: llaves foráneas de detalle y pago
    INSERT INTO tmp_rechazo
    SELECT 'detalle_pedido', d.id_detalle, 'INT-02', format('producto %s inexistente', d.id_producto)
    FROM bronce.detalle_pedido d
    WHERE NOT EXISTS (SELECT 1 FROM plata.producto pr WHERE pr.id_producto = d.id_producto)
    UNION ALL
    SELECT 'pago', g.id_pago, 'INT-02', format('método %s inexistente', g.id_metodo)
    FROM bronce.pago g
    WHERE NOT EXISTS (SELECT 1 FROM plata.metodo_pago m WHERE m.id_metodo = g.id_metodo);

    CREATE INDEX ON tmp_rechazo (tabla, id);
    ANALYZE tmp_rechazo;

    -- Registrar resultado de las reglas NEG / INT-01 / INT-02 (incluye las que dieron 0)
    INSERT INTO plata.control_calidad (lote_id, codigo_regla, filas_evaluadas, filas_afectadas)
    SELECT v_lote, rc.codigo,
           CASE rc.codigo
                WHEN 'NEG-08' THEN (SELECT count(*) FROM bronce.calificacion)
                WHEN 'INT-02' THEN (SELECT count(*) FROM bronce.detalle_pedido) + (SELECT count(*) FROM bronce.pago)
                WHEN 'NEG-09' THEN (SELECT count(*) FROM bronce.pedido) + (SELECT count(*) FROM bronce.detalle_pedido)
                                 + (SELECT count(*) FROM bronce.pago)   + (SELECT count(*) FROM bronce.calificacion)
                ELSE (SELECT count(*) FROM bronce.pedido) END,
           (SELECT count(*) FROM tmp_rechazo t WHERE t.regla = rc.codigo)
    FROM plata.regla_calidad rc
    WHERE rc.tipo = 'NEG' OR rc.codigo IN ('INT-01', 'INT-02');

    INSERT INTO plata.cuarentena (lote_id, tabla, id_registro, codigo_regla, detalle)
    SELECT v_lote, tabla, id, regla, detalle FROM tmp_rechazo;

    RAISE NOTICE '  3. Reglas de negocio: % s, % registros a cuarentena',
                 round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1),
                 (SELECT count(*) FROM tmp_rechazo);

    -- =================================================================
    -- 4. TRANSACCIONES (solo las que pasaron la validación)
    -- =================================================================
    v_t0 := clock_timestamp();
    INSERT INTO plata.pedido (id_pedido, id_cliente, id_restaurante, id_repartidor, id_promocion, id_zona,
                              fecha_hora_pedido, fecha_pedido, hora_pedido, fecha_hora_entrega, minutos_entrega,
                              estado, es_cancelado, es_abierto, es_atipico, tiene_repartidor, tiene_promocion,
                              subtotal, costo_envio, descuento, total, _lote_id)
    SELECT p.id_pedido, p.id_cliente, p.id_restaurante,
           p.id_repartidor, p.id_promocion,                                          -- INT-03: NULL se conserva
           r.id_zona,
           p.fecha_hora_pedido,
           p.fecha_hora_pedido::date,
           extract(hour FROM p.fecha_hora_pedido)::smallint,
           p.fecha_hora_entrega,
           m.minutos,                                                                -- DER-01
           lower(btrim(p.estado)),
           p.estado = 'cancelado',
           p.estado IN ('en camino', 'en preparacion'),                              -- DOM-01
           coalesce(m.minutos > v_lim, false),                                       -- DER-02
           p.id_repartidor IS NOT NULL,
           p.id_promocion IS NOT NULL,
           p.subtotal, p.costo_envio, p.descuento, p.total, v_lote
    FROM bronce.pedido p
    JOIN plata.restaurante r USING (id_restaurante)
    CROSS JOIN LATERAL (SELECT CASE WHEN p.estado = 'entregado'                      -- DOM-01: abiertos sin tiempo
                                    THEN round((extract(epoch FROM p.fecha_hora_entrega - p.fecha_hora_pedido) / 60)::numeric, 1)
                               END AS minutos) m
    WHERE NOT EXISTS (SELECT 1 FROM tmp_rechazo t WHERE t.tabla = 'pedido' AND t.id = p.id_pedido);
    ANALYZE plata.pedido;
    RAISE NOTICE '  4. pedido: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    -- Los hijos solo entran si su pedido está en plata
    v_t0 := clock_timestamp();
    INSERT INTO plata.detalle_pedido (id_detalle, id_pedido, id_producto, cantidad, precio_unitario, subtotal_linea, _lote_id)
    SELECT d.id_detalle, d.id_pedido, d.id_producto, d.cantidad,
           d.precio_unitario,                                                        -- DER-05: precio histórico del detalle
           d.subtotal_linea, v_lote
    FROM bronce.detalle_pedido d
    JOIN plata.pedido p USING (id_pedido)
    WHERE NOT EXISTS (SELECT 1 FROM tmp_rechazo t WHERE t.tabla = 'detalle_pedido' AND t.id = d.id_detalle);
    RAISE NOTICE '     detalle_pedido: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    v_t0 := clock_timestamp();
    INSERT INTO plata.pago (id_pago, id_pedido, id_metodo, monto, fecha_pago, estado, es_venta, _lote_id)
    SELECT g.id_pago, g.id_pedido, g.id_metodo, g.monto, g.fecha_pago, lower(btrim(g.estado)),
           lower(btrim(g.estado)) = 'aprobado',                                      -- DER-03
           v_lote
    FROM bronce.pago g
    JOIN plata.pedido p USING (id_pedido)
    WHERE NOT EXISTS (SELECT 1 FROM tmp_rechazo t WHERE t.tabla = 'pago' AND t.id = g.id_pago);
    RAISE NOTICE '     pago: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    v_t0 := clock_timestamp();
    INSERT INTO plata.calificacion (id_calificacion, id_pedido, puntaje_restaurante, puntaje_repartidor,
                                    comentario, tiene_comentario, tiene_emoji, fecha, _lote_id)
    SELECT c.id_calificacion, c.id_pedido, c.puntaje_restaurante, c.puntaje_repartidor,
           coalesce(k.limpio, 'Sin comentario'),                                     -- CAL-04 / CAL-05 / CAL-06
           k.limpio IS NOT NULL,
           coalesce(c.comentario ~ c_emoji, false),                                  -- CAL-05
           c.fecha, v_lote
    FROM bronce.calificacion c
    JOIN plata.pedido p USING (id_pedido)
    CROSS JOIN LATERAL (SELECT nullif(btrim(regexp_replace(regexp_replace(c.comentario, c_emoji, '', 'g'),
                                                           '\s+', ' ', 'g')), '') AS limpio) k
    WHERE NOT EXISTS (SELECT 1 FROM tmp_rechazo t WHERE t.tabla = 'calificacion' AND t.id = c.id_calificacion);
    RAISE NOTICE '     calificacion: % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);

    ANALYZE plata.detalle_pedido; ANALYZE plata.pago; ANALYZE plata.calificacion;

    -- =================================================================
    -- 5. CIERRE DEL LOTE
    -- =================================================================
    UPDATE plata.control_lote SET fecha_fin = clock_timestamp(), estado = 'ok' WHERE lote_id = v_lote;
    RAISE NOTICE 'Lote plata % terminado', v_lote;
END $$;

COMMENT ON PROCEDURE plata.sp_cargar_plata() IS
  'Transforma bronce -> plata: limpieza, anonimización, campos derivados, IQR, reglas de negocio y cuarentena.';
