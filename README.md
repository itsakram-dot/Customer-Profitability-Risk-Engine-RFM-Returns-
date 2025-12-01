# Customer Profitability & Risk Engine (RFM + Returns) (SQL → Power BI)
SQLite + Power BI project that surfaces **Margin Drainers** — customers who look valuable on revenue but destroy margin on returns.

<img width="1148" height="650" alt="Screenshot 2025-11-30 at 23 23 40" src="https://github.com/user-attachments/assets/94aa6202-7fbc-4267-ab00-89ad41a43278" />

## Problem
Classic RFM treats all revenue as good revenue. It can’t answer: **Which high-spend customers are unprofitable because of returns?**

## Data
- **Input:** invoice-level `online_retail_II`
- **Output:** customer-level `Result_14.csv`
- **Grain:** 1 row per `CustomerID` with  
  `Recency_Days • Frequency • Monetary_NetSales (Net) • GrossSales • ReturnsValue • ReturnRate • CohortMonth • R/F/M scores • RFM_Segment`

**Snapshot (this dataset)**
- Customers: ~**7,000**
- **Gross sales:** ~**£41.2bn**
- **Net sales:** ~**£41.2bn**
- **Returns value:** ~**£1.03M**  → **% returned (gross): ~0.0025%**
- Segment mix by net sales (approx): **At-Risk ~£22.4bn**, **Hibernating ~£10.9bn**, **Lost ~£7.8bn**

> Currency = **GBP**. These are **revenue** figures (no COGS).

## Method

### 1) SQL (see `RFM.sql`)
- **Stable “as-of”:** `report_date = max(InvoiceDate) + 1 day` (no leakage; recency is repeatable).
- **Returns logic:** credit notes (`Invoice LIKE 'C%'`) remain separate rows on **return date**.  
  `ReturnRate = ReturnsValue / GrossSales`.
- **RFM:** quintiles via `CUME_DIST` over Recency (ASC), Frequency (DESC), Monetary (DESC).
- **Business overlay:**  
  `Margin Drainers = ReturnRate >= 0.50 AND Frequency > 2` (thresholds are tunable).

### 2) Power BI
- **Measures:** `Total Net Sales, Gross Sales, Returns Value, % Returned Value, Customer Count, Avg Recency (Days), Avg Frequency`.
- **Pages**
  1. **Executive Overview** — KPI cards; 1-line narrative.
<img width="1148" height="650" alt="Screenshot 2025-12-01 at 09 57 19" src="https://github.com/user-attachments/assets/d967ab54-485c-4668-9cc7-32f1c4c12eae" />

  2. **Segment Mix** — treemap sized by **Net Sales** with tooltips (Avg Recency, ReturnRate).
<img width="1148" height="650" alt="Screenshot 2025-12-01 at 09 57 28" src="https://github.com/user-attachments/assets/b88a3691-cf09-4d7b-8506-a620e88d46a1" />

  3. **Risk vs Value** — bubble chart (**X = Return Rate %**, **Y = Net Sales**, **Size = Gross Sales**, color by Risk Flag). Reference lines at **10% (watchlist)** and **30% (high-risk)**. Two tables: **Top customers (low returns)** and **Margin Drainers**.
<img width="1148" height="650" alt="Screenshot 2025-11-30 at 23 23 40" src="https://github.com/user-attachments/assets/5a846afc-5b06-4d40-a4bd-061b3a240c2e" />

  4. **Customer Details** — multi-row card, monthly spend sparkline, and detail table; opened via cross-filter or drill-through.
<img width="1148" height="650" alt="Screenshot 2025-12-01 at 09 58 55" src="https://github.com/user-attachments/assets/68bce53c-b96b-4598-b82e-796eeca90abe" />

## Why this matters (actions)
- **Retention:** focus offers on **At-Risk**; monitor drift in return rate.
- **Protection:** keep **Champions/Top Spenders** healthy; watch early churn signals.
- **Reactivation:** target **Hibernating/Lost** by cohort.
- **Margin control:** review **Margin Drainers** before incentives; check product/ops quality; adjust limits.

## Reproduce

1. **SQLite**: load raw CSV as table `online_retail_II`, then run `RFM.sql`.  
   Export `Result_14.csv`.
2. **Power BI**: import `Result_14.csv`, add measures below, and open the report pages.

### DAX (copy/paste)
```DAX
Total Net Sales      = SUM('Result_14'[Monetary_NetSales])
Gross Sales          = SUM('Result_14'[GrossSales])
Returns Value        = SUM('Result_14'[ReturnsValue])
% Returned Value     = DIVIDE([Returns Value], [Gross Sales])

Customer Count       = DISTINCTCOUNT('Result_14'[CustomerID])
Avg Recency (Days)   = AVERAGE('Result_14'[Recency_Days])
Avg Frequency        = AVERAGE('Result_14'[Frequency])

% Revenue from Champions =
DIVIDE(
    CALCULATE([Total Net Sales], 'Result_14'[RFM_Segment] = "Champions"),
    [Total Net Sales]
)

Risk Flag =
IF('Result_14'[RFM_Segment] = "Margin Drainers" || 'Result_14'[ReturnRate] > 0.5,
   "High Risk", "OK")

M_X ReturnRate = 'Result_14'[ReturnRate] * 1.0   // helper for axes/formatting
