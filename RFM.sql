/* RFM + returns risk segmentation on invoice data.
   Snapshot is taken at a fixed report date to make recency stable.
   Uses SQLite window function.
*/

WITH
-- 0) Report date = last invoice date + 1 day (for recency math)
ReportDate AS (
  SELECT DATE(MAX(datetime("InvoiceDate")), '+1 day') AS report_date
  FROM online_retail_II
),

-- 1) Clean transaction log:
--    - cast types
--    - compute line value
--    - mark returns (Invoice starting with 'C')
--    - split gross vs return value
--    - drop rows without customer, non-positive price, or zero quantity
Clean_Transactions AS (
  SELECT
    CAST("Customer ID" AS TEXT)  AS CustomerID,
    CAST("Invoice"      AS TEXT) AS InvoiceNo,
    datetime("InvoiceDate")      AS InvoiceDate,

    CAST("Quantity" * "Price" AS REAL) AS LineItemValue,

    CASE WHEN "Invoice" LIKE 'C%' THEN 1 ELSE 0 END AS IsReturn,

    CASE WHEN "Invoice" LIKE 'C%' THEN 0 ELSE CAST("Quantity" * "Price" AS REAL) END AS GrossValue,
    CASE WHEN "Invoice" LIKE 'C%' THEN ABS(CAST("Quantity" * "Price" AS REAL)) ELSE 0 END AS ReturnValue
  FROM online_retail_II
  WHERE
    "Customer ID" IS NOT NULL
    AND "Price" > 0
    AND "Quantity" <> 0
),

-- 2) Aggregate to customer grain:
--    - Recency uses purchase dates only (excludes returns)
--    - Frequency = distinct purchase invoices
--    - Monetary = net sales (sales + returns; returns are negative in LineItemValue)
--    - Keep gross, returns, return rate, first purchase date
--    - Drop customers with no gross sales
Customer_Aggregates AS (
  SELECT
    c.CustomerID,
    (julianday((SELECT report_date FROM ReportDate))
      - julianday(MAX(CASE WHEN c.IsReturn = 0 THEN c.InvoiceDate END))
    ) AS Recency,
    COUNT(DISTINCT CASE WHEN c.IsReturn = 0 THEN c.InvoiceNo END) AS Frequency,
    SUM(c.LineItemValue)  AS Monetary,
    SUM(c.GrossValue)     AS GrossSales,
    SUM(c.ReturnValue)    AS ReturnsValue,
    (1.0 * SUM(c.ReturnValue)) / NULLIF(SUM(c.GrossValue), 0) AS ReturnRate,
    MIN(CASE WHEN c.IsReturn = 0 THEN c.InvoiceDate END) AS FirstPurchaseDate
  FROM Clean_Transactions c
  GROUP BY c.CustomerID
  HAVING COALESCE(SUM(c.GrossValue), 0) > 0
),

-- 3) Percentile ranks:
--    - Recency: lower is better → ASC
--    - Frequency/Monetary: higher is better → DESC
Scored AS (
  SELECT
    ca.*,
    CUME_DIST() OVER (ORDER BY ca.Recency  ASC) AS recency_cd,
    CUME_DIST() OVER (ORDER BY ca.Frequency DESC) AS freq_cd,
    CUME_DIST() OVER (ORDER BY ca.Monetary  DESC) AS mon_cd
  FROM Customer_Aggregates ca
),

-- 4) Map percentiles to 1–5 scores (5 = best)
RFM_Scores AS (
  SELECT
    s.CustomerID,
    s.Recency,
    s.Frequency,
    s.Monetary,
    s.GrossSales,
    s.ReturnsValue,
    s.ReturnRate,
    s.FirstPurchaseDate,

    CASE
      WHEN s.recency_cd <= 0.20 THEN 5
      WHEN s.recency_cd <= 0.40 THEN 4
      WHEN s.recency_cd <= 0.60 THEN 3
      WHEN s.recency_cd <= 0.80 THEN 2
      ELSE 1
    END AS R_Score,

    CASE
      WHEN s.freq_cd <= 0.20 THEN 5
      WHEN s.freq_cd <= 0.40 THEN 4
      WHEN s.freq_cd <= 0.60 THEN 3
      WHEN s.freq_cd <= 0.80 THEN 2
      ELSE 1
    END AS F_Score,

    CASE
      WHEN s.mon_cd <= 0.20 THEN 5
      WHEN s.mon_cd <= 0.40 THEN 4
      WHEN s.mon_cd <= 0.60 THEN 3
      WHEN s.mon_cd <= 0.80 THEN 2
      ELSE 1
    END AS M_Score
  FROM Scored s
)

-- 5) Final output:
--    - rounded fields
--    - cohort month
--    - concatenated score
--    - segment labels (Margin Drainers first so they’re easy to spot)
SELECT
  rs.CustomerID,
  ROUND(rs.Recency, 1)                    AS Recency_Days,
  rs.Frequency,
  ROUND(rs.Monetary, 2)                   AS Monetary_NetSales,
  ROUND(rs.GrossSales, 2)                 AS GrossSales,
  ROUND(rs.ReturnsValue, 2)               AS ReturnsValue,
  ROUND(rs.ReturnRate, 4)                 AS ReturnRate,
  STRFTIME('%Y-%m', rs.FirstPurchaseDate) AS CohortMonth,
  rs.R_Score,
  rs.F_Score,
  rs.M_Score,
  CAST(rs.R_Score AS TEXT) || CAST(rs.F_Score AS TEXT) || CAST(rs.M_Score AS TEXT) AS RFM_Score_String,

  CASE
    WHEN rs.ReturnRate > 0.50 AND rs.Frequency > 2 THEN 'Margin Drainers' -- high returns; monitor closely
    WHEN rs.R_Score = 5 AND rs.F_Score = 5 AND rs.M_Score = 5 THEN 'Top Spenders'
    WHEN rs.R_Score >= 4 AND rs.F_Score >= 4 THEN 'Champions'
    WHEN rs.R_Score >= 3 AND rs.F_Score >= 3 THEN 'Loyal Customers'
    WHEN rs.R_Score >= 4 AND rs.F_Score <  2 THEN 'New Customers'
    WHEN rs.R_Score >= 3 AND rs.F_Score <  3 THEN 'Potential Loyalists'
    WHEN rs.R_Score <  3 AND rs.F_Score >= 3 THEN 'At-Risk'
    WHEN rs.R_Score <  2 AND rs.F_Score <  2 THEN 'Lost'
    ELSE 'Hibernating'
  END AS RFM_Segment

FROM RFM_Scores rs
ORDER BY Monetary_NetSales DESC, ReturnRate ASC;