-- Run from this evidence directory. No database or extensions required.
WITH samples AS (
    SELECT regexp_extract(filename, 'trial-([123])/', 1)::INTEGER AS trial, *
    FROM read_json_auto('trial-*/resources.jsonl.gz', filename=true)
), steady AS (
    SELECT *, row_number() OVER w AS position,
           count(*) OVER (PARTITION BY trial, role) // 3 AS width,
           count(*) OVER (PARTITION BY trial, role) AS total
    FROM samples WHERE phase = 'steady'
    WINDOW w AS (PARTITION BY trial, role ORDER BY elapsed_seconds)
), windows AS (
    SELECT trial, role, phase, elapsed_seconds, rss_kib, fds, threads FROM samples
    UNION ALL
    SELECT trial, role, 'steady_first_third', elapsed_seconds, rss_kib, fds, threads
    FROM steady WHERE position <= width
    UNION ALL
    SELECT trial, role, 'steady_last_third', elapsed_seconds, rss_kib, fds, threads
    FROM steady WHERE position > total - width
)
SELECT trial, role, phase, count(*) AS count,
       min(elapsed_seconds) AS elapsed_min, max(elapsed_seconds) AS elapsed_max,
       min(rss_kib) AS rss_kib_min, median(rss_kib) AS rss_kib_median, max(rss_kib) AS rss_kib_max,
       min(fds) AS fds_min, median(fds) AS fds_median, max(fds) AS fds_max,
       min(threads) AS threads_min, median(threads) AS threads_median, max(threads) AS threads_max
FROM windows GROUP BY trial, role, phase ORDER BY trial, role, phase;
