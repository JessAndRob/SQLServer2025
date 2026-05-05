/*
Pre-demo helper: find audience-friendly function candidates for Act 1.

What this does:
1) Scores "interesting" names/text by common ops keywords.
2) Boosts functions that have many near-neighbours across different owners.
3) Returns candidates you can paste into Find-SimilarFunction live.

Tune:
- @distanceThreshold: lower = stricter near-duplicates.
- Keyword list in KeywordHits CTE.
*/

DECLARE @distanceThreshold FLOAT = 0.18;

WITH Base AS (
    SELECT
        FunctionId,
        FunctionName,
        OwnerName,
        RepoName,
        FilePath,
        SearchText,
        Embedding
    FROM dbo.ScriptFunction
    WHERE Embedding IS NOT NULL
),
NearNeighbourCounts AS (
    SELECT
        a.FunctionId,
        COUNT_BIG(*) AS NeighbourCount,
        COUNT(DISTINCT b.OwnerName) AS DistinctOtherOwners
    FROM Base a
    JOIN Base b
      ON a.FunctionId < b.FunctionId
     AND a.FunctionName <> b.FunctionName
     AND ISNULL(a.OwnerName, N'') <> ISNULL(b.OwnerName, N'')
     AND VECTOR_DISTANCE('cosine', a.Embedding, b.Embedding) < @distanceThreshold
    GROUP BY a.FunctionId
),
KeywordHits AS (
    SELECT
        b.FunctionId,
        (CASE WHEN b.FunctionName LIKE N'%Backup%'        THEN 3 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Restore%'       THEN 3 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Health%'        THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Retry%'         THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Error%'         THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Log%'           THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Disk%'          THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Certificate%'   THEN 2 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Sql%'           THEN 3 ELSE 0 END) +
        (CASE WHEN b.FunctionName LIKE N'%Database%'      THEN 3 ELSE 0 END) +
        (CASE WHEN b.SearchText   LIKE N'%deadlock%'      THEN 2 ELSE 0 END) +
        (CASE WHEN b.SearchText   LIKE N'%connection%'    THEN 1 ELSE 0 END) +
        (CASE WHEN b.SearchText   LIKE N'%timeout%'       THEN 1 ELSE 0 END) +
        (CASE WHEN b.SearchText   LIKE N'%latency%'       THEN 1 ELSE 0 END)
        AS KeywordScore
    FROM Base b
)
SELECT TOP (80)
    b.FunctionId,
    b.FunctionName,
    b.OwnerName,
    b.RepoName,
    b.FilePath,
    kh.KeywordScore,
    ISNULL(nn.NeighbourCount, 0) AS NearNeighbours,
    ISNULL(nn.DistinctOtherOwners, 0) AS DistinctOtherOwners,
    (kh.KeywordScore * 10) +
    (ISNULL(nn.NeighbourCount, 0) * 2) +
    (ISNULL(nn.DistinctOtherOwners, 0) * 5) AS AudienceScore
FROM Base b
LEFT JOIN NearNeighbourCounts nn
    ON nn.FunctionId = b.FunctionId
LEFT JOIN KeywordHits kh
    ON kh.FunctionId = b.FunctionId
WHERE kh.KeywordScore > 0
ORDER BY AudienceScore DESC, kh.KeywordScore DESC, b.FunctionName;
