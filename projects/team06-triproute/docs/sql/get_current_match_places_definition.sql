-- match_places가 여러 시그니처로 중복 정의돼 있어서(오버로드) 이름만으로는 특정이
-- 안 됩니다. 먼저 어떤 시그니처들이 있는지 확인하세요.

select
    p.oid,
    p.proname,
    pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
where p.proname = 'match_places';

-- 위 결과에서 city_filter가 들어간(실제로 지금 쓰이는) 시그니처의 arguments 값을 그대로
-- 아래 자리에 넣어서 다시 실행하세요. 예:
-- select pg_get_functiondef('match_places(vector, integer, text)'::regprocedure);
