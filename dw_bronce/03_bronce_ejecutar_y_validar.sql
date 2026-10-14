-- =====================================================================
-- 03_bronce_ejecutar_y_validar.sql
-- En pgAdmin: seleccionar UNA consulta a la vez y presionar F5
-- (pgAdmin solo muestra el resultado de la última consulta).
-- =====================================================================

-- (A) Ejecutar la carga  (~1-2 min la primera vez; los mensajes salen en la pestaña "Messages")
CALL bronce.sp_cargar_bronce();

-- (B) Resumen del último lote: filas en origen vs. filas en bronce (deben coincidir)
SELECT c.tabla, c.modo_carga, c.filas_origen, c.filas_cargadas,
       c.marca_agua_ini, c.marca_agua_fin, c.segundos
FROM bronce.control_carga c
WHERE c.lote_id = (SELECT max(lote_id) FROM bronce.control_lote)
ORDER BY c.filas_origen DESC;

-- (C) Conciliación origen vs. bronce: la columna "diferencia" debe dar 0 en todas
SELECT tabla, origen, bronce, origen - bronce AS diferencia FROM (
  SELECT 'zona' tabla, (SELECT count(*) FROM public.zona) origen, (SELECT count(*) FROM bronce.zona) bronce UNION ALL
  SELECT 'categoria_cocina', (SELECT count(*) FROM public.categoria_cocina), (SELECT count(*) FROM bronce.categoria_cocina) UNION ALL
  SELECT 'metodo_pago',      (SELECT count(*) FROM public.metodo_pago),      (SELECT count(*) FROM bronce.metodo_pago) UNION ALL
  SELECT 'promocion',        (SELECT count(*) FROM public.promocion),        (SELECT count(*) FROM bronce.promocion) UNION ALL
  SELECT 'cliente',          (SELECT count(*) FROM public.cliente),          (SELECT count(*) FROM bronce.cliente) UNION ALL
  SELECT 'restaurante',      (SELECT count(*) FROM public.restaurante),      (SELECT count(*) FROM bronce.restaurante) UNION ALL
  SELECT 'producto',         (SELECT count(*) FROM public.producto),         (SELECT count(*) FROM bronce.producto) UNION ALL
  SELECT 'repartidor',       (SELECT count(*) FROM public.repartidor),       (SELECT count(*) FROM bronce.repartidor) UNION ALL
  SELECT 'pedido',           (SELECT count(*) FROM public.pedido),           (SELECT count(*) FROM bronce.pedido) UNION ALL
  SELECT 'detalle_pedido',   (SELECT count(*) FROM public.detalle_pedido),   (SELECT count(*) FROM bronce.detalle_pedido) UNION ALL
  SELECT 'pago',             (SELECT count(*) FROM public.pago),             (SELECT count(*) FROM bronce.pago) UNION ALL
  SELECT 'calificacion',     (SELECT count(*) FROM public.calificacion),     (SELECT count(*) FROM bronce.calificacion)
) x ORDER BY origen DESC;

-- (D) Historial de lotes
SELECT * FROM bronce.control_lote ORDER BY lote_id;

-- (E) Ver cómo queda un registro en bronce (con sus columnas de auditoría).
--     Fíjense que los problemas de calidad siguen ahí: bronce no limpia.
SELECT id_cliente, nombre, email, telefono, genero, _fecha_carga, _lote_id, _origen
FROM bronce.cliente
WHERE telefono IS NULL OR telefono LIKE '+57%' OR email <> lower(email)
LIMIT 20;

-- (F) PRUEBA DE CARGA INCREMENTAL (opcional, para demostrarlo en la sustentación)
--   1. Simular un pedido nuevo en el OLTP:
INSERT INTO public.pedido
SELECT id_pedido + 1, id_cliente, id_restaurante, id_repartidor, id_promocion,
       now(), NULL, 'en preparacion', subtotal, costo_envio, descuento, total
FROM public.pedido ORDER BY id_pedido DESC LIMIT 1;
--   2. Volver a correr la carga:   CALL bronce.sp_cargar_bronce();
--   3. Repetir la consulta (B): pedido debe mostrar filas_cargadas = 1
--      (solo trajo el nuevo); los maestros se recargan completos.
--   4. Deshacer la simulación:
DELETE FROM public.pedido WHERE id_pedido = (SELECT max(id_pedido) FROM public.pedido) AND fecha_hora_pedido > '2026-07-01';
DELETE FROM bronce.pedido WHERE id_pedido = (SELECT max(id_pedido) FROM bronce.pedido) AND fecha_hora_pedido > '2026-07-01';
