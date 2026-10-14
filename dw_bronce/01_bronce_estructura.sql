-- =====================================================================
-- 01_bronce_estructura.sql
-- CAPA BRONCE - Estructura
-- Copia cruda del OLTP (esquema public) + columnas de auditoría.
-- Bronce NO limpia ni transforma nada: guarda el dato tal como llegó.
--
-- Ejecutar en pgAdmin (Query Tool) sobre la base delivery_oltp.
-- OJO: borra y vuelve a crear el esquema bronce.
-- =====================================================================

DROP SCHEMA IF EXISTS bronce CASCADE;
CREATE SCHEMA bronce;
COMMENT ON SCHEMA bronce IS 'Capa bronce: datos crudos extraídos del OLTP, sin transformar, con auditoría de carga';

-- ---------------------------------------------------------------------
-- 1. Tabla de configuración: qué se extrae y cómo
--    completa    = se borra y se vuelve a cargar entera (catálogos y maestros,
--                  porque sus registros se pueden ACTUALIZAR en el OLTP)
--    incremental = solo se traen los registros con llave mayor a la última
--                  cargada (transacciones: solo se INSERTAN, crecen con el tiempo)
-- ---------------------------------------------------------------------
CREATE TABLE bronce.config_extraccion (
    tabla        VARCHAR(40) PRIMARY KEY,
    llave        VARCHAR(40) NOT NULL,
    modo_carga   VARCHAR(12) NOT NULL CHECK (modo_carga IN ('completa','incremental')),
    orden        SMALLINT    NOT NULL,
    activa       BOOLEAN     NOT NULL DEFAULT TRUE
);

INSERT INTO bronce.config_extraccion (tabla, llave, modo_carga, orden) VALUES
  ('zona',             'id_zona',         'completa',     1),
  ('categoria_cocina', 'id_categoria',    'completa',     2),
  ('metodo_pago',      'id_metodo',       'completa',     3),
  ('promocion',        'id_promocion',    'completa',     4),
  ('cliente',          'id_cliente',      'completa',     5),
  ('restaurante',      'id_restaurante',  'completa',     6),
  ('producto',         'id_producto',     'completa',     7),
  ('repartidor',       'id_repartidor',   'completa',     8),
  ('pedido',           'id_pedido',       'incremental',  9),
  ('detalle_pedido',   'id_detalle',      'incremental', 10),
  ('pago',             'id_pago',         'incremental', 11),
  ('calificacion',     'id_calificacion', 'incremental', 12);

-- ---------------------------------------------------------------------
-- 2. Bitácora de cargas (auditoría): un lote por ejecución,
--    una fila por tabla cargada en ese lote
-- ---------------------------------------------------------------------
CREATE TABLE bronce.control_lote (
    lote_id       SERIAL PRIMARY KEY,
    fecha_inicio  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    fecha_fin     TIMESTAMPTZ,
    usuario       VARCHAR(60) NOT NULL DEFAULT current_user,
    estado        VARCHAR(12) NOT NULL DEFAULT 'en curso'
);

CREATE TABLE bronce.control_carga (
    lote_id         INT          NOT NULL REFERENCES bronce.control_lote,
    tabla           VARCHAR(40)  NOT NULL,
    modo_carga      VARCHAR(12)  NOT NULL,
    marca_agua_ini  BIGINT,          -- última llave que había antes de la carga
    marca_agua_fin  BIGINT,          -- última llave después de la carga
    filas_origen    BIGINT,          -- filas que tiene la tabla en el OLTP
    filas_cargadas  BIGINT,          -- filas insertadas en bronce en este lote
    segundos        NUMERIC(10,2),
    PRIMARY KEY (lote_id, tabla)
);

-- ---------------------------------------------------------------------
-- 3. Tablas bronce: mismas columnas que el OLTP + 3 de auditoría.
--    Se crean con CREATE TABLE AS ... WITH NO DATA, así copian los tipos
--    pero NO las restricciones (NOT NULL, PK, FK, CHECK): bronce acepta
--    el dato como venga; las validaciones se hacen en plata.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT tabla FROM bronce.config_extraccion ORDER BY orden LOOP
        EXECUTE format(
            'CREATE TABLE bronce.%1$I AS
               SELECT s.*,
                      now()::timestamptz  AS _fecha_carga,
                      0::int              AS _lote_id,
                      ''''::varchar(60)   AS _origen
               FROM public.%1$I s
             WITH NO DATA', t.tabla);
        EXECUTE format(
            'COMMENT ON TABLE bronce.%1$I IS %2$L',
            t.tabla, 'Bronce: copia cruda de public.' || t.tabla);
    END LOOP;
END $$;
