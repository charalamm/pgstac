CREATE TABLE queryables (
    id bigint GENERATED ALWAYS AS identity PRIMARY KEY,
    name text UNIQUE NOT NULL,
    collection_ids text[], -- used to determine what partitions to create indexes on
    definition jsonb,
    property_path text,
    property_wrapper text,
    property_index_type text,
    summarize text,
);
CREATE INDEX queryables_name_idx ON queryables (name);
CREATE INDEX queryables_property_wrapper_idx ON queryables (property_wrapper);


INSERT INTO queryables (name, definition) VALUES
('id', '{"title": "Item ID","description": "Item identifier","$ref": "https://schemas.stacspec.org/v1.0.0/item-spec/json-schema/item.json#/definitions/core/allOf/2/properties/id"}'),
('datetime','{"description": "Datetime","type": "string","title": "Acquired","format": "date-time","pattern": "(\\+00:00|Z)$"}'),
('geometry', '{"title": "Item Geometry","description": "Item Geometry","$ref": "https://geojson.org/schema/Feature.json"}')
ON CONFLICT DO NOTHING;

INSERT INTO queryables (name, definition, property_wrapper, property_index_type) VALUES
('eo:cloud_cover','{"$ref": "https://stac-extensions.github.io/eo/v1.0.0/schema.json#/definitions/fieldsproperties/eo:cloud_cover"}','to_int','BTREE')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION array_to_path(arr text[]) RETURNS text AS $$
    SELECT string_agg(
        quote_literal(v),
        '->'
    ) FROM unnest(arr) v;
$$ LANGUAGE SQL IMMUTABLE STRICT;




CREATE OR REPLACE FUNCTION queryable(
    IN dotpath text,
    OUT path text,
    OUT expression text,
    OUT wrapper text,
    OUT nulled_wrapper text
) AS $$
DECLARE
    q RECORD;
    path_elements text[];
BEGIN
    IF dotpath IN ('id', 'geometry', 'datetime', 'end_datetime', 'collection') THEN
        path := dotpath;
        expression := dotpath;
        wrapper := NULL;
        RETURN;
    END IF;
    SELECT * INTO q FROM queryables
        WHERE
            name=dotpath
            OR name = 'properties.' || dotpath
            OR name = replace(dotpath, 'properties.', '')
    ;
    IF q.property_wrapper IS NULL THEN
        IF q.definition->>'type' = 'number' THEN
            wrapper := 'to_float';
            nulled_wrapper := wrapper;
        ELSIF q.definition->>'format' = 'date-time' THEN
            wrapper := 'to_tstz';
            nulled_wrapper := wrapper;
        ELSE
            nulled_wrapper := NULL;
            wrapper := 'to_text';
        END IF;
    ELSE
        wrapper := q.property_wrapper;
        nulled_wrapper := wrapper;
    END IF;
    IF q.property_path IS NOT NULL THEN
        path := q.property_path;
    ELSE
        path_elements := string_to_array(dotpath, '.');
        IF path_elements[1] IN ('links', 'assets', 'stac_version', 'stac_extensions') THEN
            path := format('content->%s', array_to_path(path_elements));
        ELSIF path_elements[1] = 'properties' THEN
            path := format('content->%s', array_to_path(path_elements));
        ELSE
            path := format($F$content->'properties'->%s$F$, array_to_path(path_elements));
        END IF;
    END IF;
    expression := format('%I(%s)', wrapper, path);
    RETURN;
END;
$$ LANGUAGE PLPGSQL STABLE STRICT;


CREATE OR REPLACE FUNCTION maintain_partition_queries(
    part text DEFAULT 'items',
    dropindexes boolean DEFAULT FALSE,
    rebuildindexes boolean DEFAULT FALSE
) RETURNS SETOF text AS $$
DECLARE
    parent text;
    level int;
    isleaf bool;
    collection collections%ROWTYPE;
    subpart text;
    baseidx text;
    queryable_name text;
    queryable_property_index_type text;
    queryable_property_wrapper text;
    queryable_parsed RECORD;
    deletedidx pg_indexes%ROWTYPE;
    q text;
    idx text;
    collection_partition bigint;
BEGIN
    RAISE NOTICE 'Maintaining partition: %', part;

    -- Get root partition
    SELECT parentrelid::text, pt.isleaf, pt.level
        INTO parent, isleaf, level
    FROM pg_partition_tree('items') pt
    WHERE relid::text = part;
    IF NOT FOUND THEN
        RAISE NOTICE 'Partition % Does Not Exist In Partition Tree', part;
        RETURN;
    END IF;

    -- If this is a parent partition, recurse to leaves
    IF NOT isleaf THEN
        FOR subpart IN
            SELECT relid::text
            FROM pg_partition_tree(part)
            WHERE relid::text != part
        LOOP
            RAISE NOTICE 'Recursing to %', subpart;
            RETURN QUERY SELECT * FROM maintain_partition_queries(subpart, dropindexes, rebuildindexes);
        END LOOP;
        RETURN; -- Don't continue since not an end leaf
    END IF;


    -- Get collection
    collection_partition := ((regexp_match(part, E'^_items_([0-9]+)'))[1])::bigint;
    RAISE NOTICE 'COLLECTION PARTITION: %', collection_partition;
    SELECT * INTO STRICT collection
    FROM collections
    WHERE key = collection_partition;
    RAISE NOTICE 'COLLECTION ID: %s', collection.id;


    -- Create temp table with existing indexes
    CREATE TEMP TABLE existing_indexes ON COMMIT DROP AS
    SELECT *
    FROM pg_indexes
    WHERE schemaname='pgstac' AND tablename=part;


    -- Check if index exists for each queryable.
    FOR
        queryable_name,
        queryable_property_index_type,
        queryable_property_wrapper
    IN
        SELECT
            name,
            COALESCE(property_index_type, 'BTREE'),
            COALESCE(property_wrapper, 'to_text')
        FROM queryables
        WHERE
            name NOT in ('id', 'datetime', 'geometry')
            AND (
                collection_ids IS NULL
                OR collection_ids = '{}'::text[]
                OR collection.id = ANY (collection_ids)
            )
        UNION ALL
        SELECT 'datetime desc, end_datetime', 'BTREE', ''
        UNION ALL
        SELECT 'geometry', 'GIST', ''
        UNION ALL
        SELECT 'id', 'BTREE', ''
    LOOP
        baseidx := format(
            $q$ ON %I USING %s (%s(((content -> 'properties'::text) -> %L::text)))$q$,
            part,
            queryable_property_index_type,
            queryable_property_wrapper,
            queryable_name
        );
        RAISE NOTICE 'BASEIDX: %', baseidx;
        RAISE NOTICE 'IDXSEARCH: %', format($q$[(']%s[')]$q$, queryable_name);
        -- If index already exists, delete it from existing indexes type table
        DELETE FROM existing_indexes
        WHERE indexdef ~* format($q$[(']%s[')]$q$, queryable_name)
        RETURNING * INTO deletedidx;
        RAISE NOTICE 'EXISTING INDEX: %', deletedidx;
        IF NOT FOUND THEN -- index did not exist, create it
            RETURN NEXT format('CREATE INDEX CONCURRENTLY %s;', baseidx);
        ELSIF rebuildindexes THEN
            RETURN NEXT format('REINDEX %I CONCURRENTLY;', deletedidx.indexname);
        END IF;
    END LOOP;

    -- Remove indexes that were not expected
    IF dropindexes THEN
        FOR idx IN SELECT indexname::text FROM existing_indexes
        LOOP
            RETURN NEXT format('DROP INDEX IF EXISTS %I;', idx);
        END LOOP;
    END IF;

    DROP TABLE existing_indexes;
    RETURN;

END;
$$ LANGUAGE PLPGSQL;

CREAET OR REPLACE FUNCTION maintain_partitions(
    part text DEFAULT items,
    dropindexes boolean DEFAULT FALSE,
    rebuildindexes boolean DEFAULT FALSE
) RETURNS VOID AS $$
    WITH t AS (
        SELECT run_or_queue(q) FROM maintain_partitions_queries(part, dropindexes, rebuildindexes) q
    ) SELECT count(*) FROM t;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION queryables_trigger_func() RETURNS TRIGGER AS $$
DECLARE
BEGIN
    PERFORM maintain_partitions();
    RETURN NEW;
END;
$$ LANGUAGE PLPGSQL;

CREATE TRIGGER queryables_trigger AFTER INSERT OR UPDATE ON queryables
FOR EACH STATEMENT EXECUTE PROCEDURE queryables_trigger_func();

CREATE TRIGGER queryables_collection_trigger AFTER INSERT OR UPDATE ON collections
FOR EACH STATEMENT WHEN OLD.partition_trunc IS DISTINCT FROM NEW.partition_trunc EXECUTE PROCEDURE queryables_trigger_func();

CREATE OR REPLACE FUNCTION get_queryables(_collection_ids text[] DEFAULT NULL) RETURNS jsonb AS $$
BEGIN
    -- Build up queryables if the input contains valid collection ids or is empty
    IF EXISTS (
        SELECT 1 FROM collections
        WHERE
            _collection_ids IS NULL
            OR cardinality(_collection_ids) = 0
            OR id = ANY(_collection_ids)
    )
    THEN
        RETURN (
            SELECT
                jsonb_build_object(
                    '$schema', 'http://json-schema.org/draft-07/schema#',
                    '$id', 'https://example.org/queryables',
                    'type', 'object',
                    'title', 'STAC Queryables.',
                    'properties', jsonb_object_agg(
                        name,
                        definition
                    )
                )
                FROM queryables
                WHERE
                    _collection_ids IS NULL OR
                    cardinality(_collection_ids) = 0 OR
                    collection_ids IS NULL OR
                    _collection_ids && collection_ids
        );
    ELSE
        RETURN NULL;
    END IF;
END;

$$ LANGUAGE PLPGSQL STABLE;

CREATE OR REPLACE FUNCTION get_queryables(_collection text DEFAULT NULL) RETURNS jsonb AS $$
    SELECT
        CASE
            WHEN _collection IS NULL THEN get_queryables(NULL::text[])
            ELSE get_queryables(ARRAY[_collection])
        END
    ;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION missing_queryables(_collection text, _tablesample int DEFAULT 5) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
DECLARE
    q text;
    _partition text;
    explain_json json;
    psize bigint;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;

    EXECUTE format('EXPLAIN (format json) SELECT 1 FROM %I;', _partition)
    INTO explain_json;
    psize := explain_json->0->'Plan'->'Plan Rows';
    IF _tablesample * .01 * psize < 10 THEN
        _tablesample := 100;
    END IF;
    RAISE NOTICE 'Using tablesample % to find missing queryables from % % that has ~% rows', _tablesample, _collection, _partition, psize;

    q := format(
        $q$
            WITH q AS (
                SELECT * FROM queryables
                WHERE
                    collection_ids IS NULL
                    OR %L = ANY(collection_ids)
            ), t AS (
                SELECT
                    content->'properties' AS properties
                FROM
                    %I
                TABLESAMPLE SYSTEM(%L)
            ), p AS (
                SELECT DISTINCT ON (key)
                    key,
                    value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                LEFT JOIN q ON (q.name=key)
                WHERE q.definition IS NULL
            )
            SELECT
                %L,
                key,
                jsonb_build_object('type',jsonb_typeof(value)) as definition,
                CASE jsonb_typeof(value)
                    WHEN 'number' THEN 'to_float'
                    WHEN 'array' THEN 'to_text_array'
                    ELSE 'to_text'
                END
            FROM p;
        $q$,
        _collection,
        _partition,
        _tablesample,
        _collection
    );
    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION missing_queryables(_tablesample int DEFAULT 5) RETURNS TABLE(collection_ids text[], name text, definition jsonb, property_wrapper text) AS $$
    SELECT
        array_agg(collection),
        name,
        definition,
        property_wrapper
    FROM
        collections
        JOIN LATERAL
        missing_queryables(id, _tablesample) c
        ON TRUE
    GROUP BY
        2,3,4
    ORDER BY 2,1
    ;
$$ LANGUAGE SQL;
