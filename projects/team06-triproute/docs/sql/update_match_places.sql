DROP FUNCTION IF EXISTS public.match_places(vector, integer, text);

CREATE OR REPLACE FUNCTION public.match_places(query_embedding vector, match_count integer DEFAULT 5, city_filter text DEFAULT NULL::text)
 RETURNS TABLE(id bigint, content_id text, title text, overview text, address text, category text, rating numeric, review_count integer, latitude double precision, longitude double precision, similarity double precision)
 LANGUAGE sql
 STABLE
AS $function$
    select id, content_id, title, overview, address, category, rating, review_count, latitude, longitude,
           1 - (embedding <=> query_embedding) as similarity
    from places
    where (city_filter is null or address like '%' || city_filter || '%')
      and (category is null or category <> '여행코스')
    order by embedding <=> query_embedding
    limit match_count;
$function$;
