-- =====================================================================
-- 02_oro_procedimiento.sql
-- CAPA ORO - Procedimiento de Carga (plata -> oro)
--
-- Crea el procedimiento oro.sp_cargar_oro() que:
--   1. Inserta los miembros -1 ("No aplica") en las dimensiones
--   2. Carga / Actualiza las 8 dimensiones desde Plata
--   3. Carga Fact Pedido y Fact Detalle Pedido cruzando con SKs
--   4. Refresca las Vistas Materializadas para Grafana
-- =====================================================================

CREATE OR REPLACE PROCEDURE oro.sp_cargar_oro()
LANGUAGE plpgsql
AS $$
DECLARE
    v_t0 TIMESTAMPTZ;
BEGIN
    v_t0 := clock_timestamp();
    RAISE NOTICE 'Iniciando carga de Capa Oro...';

    -- -----------------------------------------------------------------
    -- 1. LIMPIEZA DE TABLAS DE HECHOS Y DIMENSIONES
    -- -----------------------------------------------------------------
    TRUNCATE oro.fact_detalle_pedido, oro.fact_pedido CASCADE;
    TRUNCATE oro.dim_producto, oro.dim_promocion, oro.dim_repartidor,
             oro.dim_restaurante, oro.dim_cliente, oro.dim_zona,
             oro.dim_metodo_pago, oro.dim_tiempo CASCADE;

    -- -----------------------------------------------------------------
    -- 2. INSERTAR MIEMBROS -1 ("NO APLICA")
    -- -----------------------------------------------------------------
    INSERT INTO oro.dim_tiempo (sk_tiempo, fecha, anio, trimestre, mes, nombre_mes, dia, dia_semana, nombre_dia, es_fin_semana)
    VALUES (-1, '1900-01-01', 1900, 0, 0, 'No aplica', 0, 0, 'No aplica', FALSE);

    INSERT INTO oro.dim_zona (sk_zona, id_zona, ciudad, nombre_zona, codigo_postal, tarifa_base_envio)
    VALUES (-1, -1, 'No aplica', 'No aplica', '00000', 0);

    INSERT INTO oro.dim_cliente (sk_cliente, id_cliente, nombre, dominio_email, email_valido, telefono_valido, edad, rango_edad, genero, genero_desc, id_zona, fecha_registro)
    VALUES (-1, -1, 'No aplica', 'N/A', FALSE, FALSE, NULL, 'Sin dato', 'N', 'No aplica', -1, '1900-01-01 00:00:00');

    INSERT INTO oro.dim_restaurante (sk_restaurante, id_restaurante, nombre, categoria_cocina, id_zona, fecha_alta, estado)
    VALUES (-1, -1, 'No aplica', 'No aplica', -1, '1900-01-01', 'inactivo');

    INSERT INTO oro.dim_repartidor (sk_repartidor, id_repartidor, nombre, tipo_vehiculo, id_zona, fecha_ingreso, estado)
    VALUES (-1, -1, 'No aplica / Sin repartidor', 'No aplica', -1, '1900-01-01', 'inactivo');

    INSERT INTO oro.dim_promocion (sk_promocion, id_promocion, codigo, tipo_descuento, valor, fecha_inicio, fecha_fin, duracion_dias)
    VALUES (-1, -1, 'SIN_PROMO', 'Sin descuento', 0, '1900-01-01', '1900-01-01', 0);

    INSERT INTO oro.dim_metodo_pago (sk_metodo_pago, id_metodo, nombre, tipo_metodo)
    VALUES (-1, -1, 'No aplica', 'No aplica');

    INSERT INTO oro.dim_producto (sk_producto, id_producto, nombre, tipo_producto, precio_actual, id_restaurante, restaurante_nombre, activo)
    VALUES (-1, -1, 'No aplica', 'No aplica', 0, -1, 'No aplica', FALSE);

    -- -----------------------------------------------------------------
    -- 3. POBLAR DIMENSIONES DESDE PLATA
    -- -----------------------------------------------------------------
    -- Dim Tiempo
    INSERT INTO oro.dim_tiempo
    SELECT to_char(d, 'YYYYMMDD')::INT AS sk_tiempo,
           d::DATE AS fecha,
           extract(year FROM d)::SMALLINT AS anio,
           extract(quarter FROM d)::SMALLINT AS trimestre,
           extract(month FROM d)::SMALLINT AS mes,
           to_char(d, 'TMMonth') AS nombre_mes,
           extract(day FROM d)::SMALLINT AS dia,
           extract(isodow FROM d)::SMALLINT AS dia_semana,
           to_char(d, 'TMDay') AS nombre_dia,
           extract(isodow FROM d) IN (6, 7) AS es_fin_semana
    FROM generate_series(
        (SELECT min(fecha_pedido) FROM plata.pedido),
        (SELECT max(fecha_pedido) FROM plata.pedido),
        '1 day'::interval
    ) d;

    -- Dim Zona
    INSERT INTO oro.dim_zona (id_zona, ciudad, nombre_zona, codigo_postal, tarifa_base_envio)
    SELECT id_zona, ciudad, nombre_zona, codigo_postal, tarifa_base_envio FROM plata.zona;

    -- Dim Cliente
    INSERT INTO oro.dim_cliente (id_cliente, nombre, dominio_email, email_valido, telefono_valido, edad, rango_edad, genero, genero_desc, id_zona, fecha_registro)
    SELECT id_cliente, nombre, dominio_email, email_valido, telefono_valido, edad, rango_edad, genero, genero_desc, id_zona, fecha_registro FROM plata.cliente;

    -- Dim Restaurante
    INSERT INTO oro.dim_restaurante (id_restaurante, nombre, categoria_cocina, id_zona, fecha_alta, estado)
    SELECT r.id_restaurante, r.nombre, c.nombre, r.id_zona, r.fecha_alta, r.estado
    FROM plata.restaurante r JOIN plata.categoria_cocina c USING (id_categoria);

    -- Dim Repartidor
    INSERT INTO oro.dim_repartidor (id_repartidor, nombre, tipo_vehiculo, id_zona, fecha_ingreso, estado)
    SELECT id_repartidor, nombre, tipo_vehiculo, id_zona, fecha_ingreso, estado FROM plata.repartidor;

    -- Dim Promoción
    INSERT INTO oro.dim_promocion (id_promocion, codigo, tipo_descuento, valor, fecha_inicio, fecha_fin, duracion_dias)
    SELECT id_promocion, codigo, tipo_descuento, valor, fecha_inicio, fecha_fin, duracion_dias FROM plata.promocion;

    -- Dim Método Pago
    INSERT INTO oro.dim_metodo_pago (id_metodo, nombre, tipo_metodo)
    SELECT id_metodo, nombre, tipo_metodo FROM plata.metodo_pago;

    -- Dim Producto
    INSERT INTO oro.dim_producto (id_producto, nombre, tipo_producto, precio_actual, id_restaurante, restaurante_nombre, activo)
    SELECT p.id_producto, p.nombre, p.tipo_producto, p.precio_actual, p.id_restaurante, r.nombre, p.activo
    FROM plata.producto p JOIN plata.restaurante r USING (id_restaurante);

    -- -----------------------------------------------------------------
    -- 4. POBLAR FACT PEDIDO
    -- -----------------------------------------------------------------
    INSERT INTO oro.fact_pedido
    SELECT p.id_pedido,
           coalesce(dt.sk_tiempo, -1),
           coalesce(dc.sk_cliente, -1),
           coalesce(dr.sk_restaurante, -1),
           coalesce(drp.sk_repartidor, -1),
           coalesce(dp.sk_promocion, -1),
           coalesce(dz.sk_zona, -1),
           coalesce(dmp.sk_metodo_pago, -1),
           p.subtotal, p.costo_envio, p.descuento, p.total,
           coalesce(det.cant_prod, 0),
           p.minutos_entrega,
           cal.puntaje_restaurante,
           cal.puntaje_repartidor,
           coalesce(pag.pagos_rechazados, 0),
           CASE WHEN p.es_cancelado THEN 1 ELSE 0 END,
           CASE WHEN p.estado = 'entregado' THEN 1 ELSE 0 END,
           p.es_atipico
    FROM plata.pedido p
    LEFT JOIN oro.dim_tiempo dt ON dt.fecha = p.fecha_pedido
    LEFT JOIN oro.dim_cliente dc ON dc.id_cliente = p.id_cliente
    LEFT JOIN oro.dim_restaurante dr ON dr.id_restaurante = p.id_restaurante
    LEFT JOIN oro.dim_repartidor drp ON drp.id_repartidor = p.id_repartidor
    LEFT JOIN oro.dim_promocion dp ON dp.id_promocion = p.id_promocion
    LEFT JOIN oro.dim_zona dz ON dz.id_zona = p.id_zona
    LEFT JOIN (
        SELECT DISTINCT ON (id_pedido) id_pedido, id_metodo
        FROM plata.pago WHERE es_venta = TRUE ORDER BY id_pedido, fecha_pago DESC
    ) pg ON pg.id_pedido = p.id_pedido
    LEFT JOIN oro.dim_metodo_pago dmp ON dmp.id_metodo = pg.id_metodo
    LEFT JOIN (
        SELECT id_pedido, sum(cantidad) AS cant_prod FROM plata.detalle_pedido GROUP BY id_pedido
    ) det ON det.id_pedido = p.id_pedido
    LEFT JOIN plata.calificacion cal ON cal.id_pedido = p.id_pedido
    LEFT JOIN (
        SELECT id_pedido, count(*) AS pagos_rechazados FROM plata.pago WHERE estado = 'rechazado' GROUP BY id_pedido
    ) pag ON pag.id_pedido = p.id_pedido;

    -- -----------------------------------------------------------------
    -- 5. POBLAR FACT DETALLE PEDIDO
    -- -----------------------------------------------------------------
    INSERT INTO oro.fact_detalle_pedido
    SELECT d.id_detalle, d.id_pedido,
           coalesce(dpr.sk_producto, -1),
           coalesce(dt.sk_tiempo, -1),
           coalesce(dc.sk_cliente, -1),
           coalesce(dr.sk_restaurante, -1),
           coalesce(dz.sk_zona, -1),
           d.cantidad, d.precio_unitario, d.subtotal_linea
    FROM plata.detalle_pedido d
    JOIN plata.pedido p ON p.id_pedido = d.id_pedido
    LEFT JOIN oro.dim_producto dpr ON dpr.id_producto = d.id_producto
    LEFT JOIN oro.dim_tiempo dt ON dt.fecha = p.fecha_pedido
    LEFT JOIN oro.dim_cliente dc ON dc.id_cliente = p.id_cliente
    LEFT JOIN oro.dim_restaurante dr ON dr.id_restaurante = p.id_restaurante
    LEFT JOIN oro.dim_zona dz ON dz.id_zona = p.id_zona;

    -- -----------------------------------------------------------------
    -- 6. CREAR / REFRESCAR VISTAS MATERIALIZADAS PARA GRAFANA
    -- -----------------------------------------------------------------
    DROP MATERIALIZED VIEW IF EXISTS oro.mv_ventas_diarias CASCADE;
    CREATE MATERIALIZED VIEW oro.mv_ventas_diarias AS
    SELECT t.fecha, t.anio, t.nombre_mes, z.nombre_zona, m.tipo_metodo,
           count(f.id_pedido) AS total_pedidos,
           sum(f.total) AS ventas_totales,
           avg(f.total) AS ticket_promedio
    FROM oro.fact_pedido f
    JOIN oro.dim_tiempo t ON f.sk_tiempo = t.sk_tiempo
    JOIN oro.dim_zona z ON f.sk_zona = z.sk_zona
    JOIN oro.dim_metodo_pago m ON f.sk_metodo_pago = m.sk_metodo_pago
    WHERE f.es_entregado = 1
    GROUP BY t.fecha, t.anio, t.nombre_mes, z.nombre_zona, m.tipo_metodo;

    DROP MATERIALIZED VIEW IF EXISTS oro.mv_entregas CASCADE;
    CREATE MATERIALIZED VIEW oro.mv_entregas AS
    SELECT z.nombre_zona, r.nombre AS repartidor, r.tipo_vehiculo,
           round(avg(f.tiempo_entrega_min), 1) AS tiempo_promedio_min,
           count(f.id_pedido) AS entregas_realizadas,
           sum(CASE WHEN f.es_atipico THEN 1 ELSE 0 END) AS entregas_atipicas
    FROM oro.fact_pedido f
    JOIN oro.dim_zona z ON f.sk_zona = z.sk_zona
    JOIN oro.dim_repartidor r ON f.sk_repartidor = r.sk_repartidor
    WHERE f.es_entregado = 1
    GROUP BY z.nombre_zona, r.nombre, r.tipo_vehiculo;

    DROP MATERIALIZED VIEW IF EXISTS oro.mv_cancelaciones CASCADE;
    CREATE MATERIALIZED VIEW oro.mv_cancelaciones AS
    SELECT z.nombre_zona, res.nombre AS restaurante,
           count(f.id_pedido) AS total_pedidos,
           sum(f.es_cancelado) AS pedidos_cancelados,
           round(100.0 * sum(f.es_cancelado) / count(f.id_pedido), 2) AS pct_cancelacion
    FROM oro.fact_pedido f
    JOIN oro.dim_zona z ON f.sk_zona = z.sk_zona
    JOIN oro.dim_restaurante res ON f.sk_restaurante = res.sk_restaurante
    GROUP BY z.nombre_zona, res.nombre;

    ANALYZE oro.fact_pedido;
    ANALYZE oro.fact_detalle_pedido;

    RAISE NOTICE 'Capa Oro cargada exitosamente en % s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);
END $$;