-- places 테이블에 좌표 컬럼을 추가한다.
--
-- 배경: 데이터 수집 시점(ingest_city)에 TourAPI로 좌표(mapx/mapy)를 이미 가져오는데
-- (Google Places 평점 매칭에 씀), 지금까지는 이 좌표를 저장하지 않고 버려서 여행 계획
-- 생성 시점에 route_planner.py가 같은 장소의 좌표를 TourAPI로 또 조회해야 했다
-- (_fill_missing_place_details, 장소당 ~2초). 좌표를 수집 시점에 같이 저장해두면
-- RAG 검색(match_places) 결과에 좌표가 바로 포함돼서 이 재조회가 필요 없어진다.

alter table places
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

-- match_places 함수도 latitude/longitude를 반환하도록 재정의해야 하는데, 지금 라이브로
-- 돌아가는 최신 버전(city_filter 파라미터, 여행코스 제외 로직 포함)의 정확한 정의를
-- 아직 확인 중이라 이 파일에는 포함하지 않았다. get_current_match_places_definition.sql로
-- 확인한 뒤 별도로 CREATE OR REPLACE FUNCTION을 추가할 예정.
