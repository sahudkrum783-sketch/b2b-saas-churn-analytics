/* ============================================================================
   PROJECT: B2B SaaS Churn Data Warehouse
   FILE: 02_star_schema_build.sql
   DESCRIPTION: Cleans tangled constraints, fixes orphan records via dummy 
                inserts, locks the Star Schema, and materializes the KPI view.
   ============================================================================ */

-- 1. WIPE EXISTING TANGLED CONSTRAINTS
ALTER TABLE analytics.fct_subscriptions DROP CONSTRAINT IF EXISTS fk_sub_cust, DROP CONSTRAINT IF EXISTS fk_sub_plan;
ALTER TABLE analytics.fct_payments DROP CONSTRAINT IF EXISTS fk_pay_sub;
ALTER TABLE analytics.fct_support DROP CONSTRAINT IF EXISTS fk_sup_cust;
ALTER TABLE analytics.dim_customers DROP CONSTRAINT IF EXISTS dim_customers_pkey CASCADE;
ALTER TABLE analytics.dim_plans DROP CONSTRAINT IF EXISTS dim_plans_pkey CASCADE;
ALTER TABLE analytics.fct_subscriptions DROP CONSTRAINT IF EXISTS fct_subscriptions_pkey CASCADE;
ALTER TABLE analytics.fct_payments DROP CONSTRAINT IF EXISTS fct_payments_pkey CASCADE;
ALTER TABLE analytics.fct_support DROP CONSTRAINT IF EXISTS fct_support_pkey CASCADE;


-- 2. CASCADE DELETE: DROP PAYMENTS FOR CORRUPTED SUBSCRIPTIONS
-- Deletes the payments belonging to the 23 time-travel subscriptions dropped during Python ELT
DELETE FROM analytics.fct_payments 
WHERE subscription_id NOT IN (SELECT subscription_id FROM analytics.fct_subscriptions);


-- 3. ORPHAN FIX: INJECT MISSING CUSTOMERS (DUMMY INSERTS)
-- Fix 121 missing customers from the Subscriptions table
INSERT INTO analytics.dim_customers (customer_id, segment, country, industry, company_size, health_score, risk_category)
SELECT DISTINCT s.customer_id, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 0, 'Critical Risk'
FROM analytics.fct_subscriptions s
LEFT JOIN analytics.dim_customers c ON s.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- Fix 68 missing customers from the Support table
INSERT INTO analytics.dim_customers (customer_id, segment, country, industry, company_size, health_score, risk_category)
SELECT DISTINCT sup.customer_id, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 0, 'Critical Risk'
FROM analytics.fct_support sup
LEFT JOIN analytics.dim_customers c ON sup.customer_id = c.customer_id
WHERE c.customer_id IS NULL;


-- 4. REBUILD PRIMARY KEYS (THE ANCHORS)
ALTER TABLE analytics.dim_customers ADD PRIMARY KEY (customer_id);
ALTER TABLE analytics.dim_plans ADD PRIMARY KEY (plan_id);
ALTER TABLE analytics.fct_subscriptions ADD PRIMARY KEY (subscription_id);
ALTER TABLE analytics.fct_payments ADD PRIMARY KEY (payment_id);
ALTER TABLE analytics.fct_support ADD PRIMARY KEY (ticket_id);


-- 5. REBUILD FOREIGN KEYS (THE BRIDGES)
ALTER TABLE analytics.fct_subscriptions 
    ADD CONSTRAINT fk_sub_cust FOREIGN KEY (customer_id) REFERENCES analytics.dim_customers(customer_id),
    ADD CONSTRAINT fk_sub_plan FOREIGN KEY (plan_id) REFERENCES analytics.dim_plans(plan_id);

ALTER TABLE analytics.fct_payments 
    ADD CONSTRAINT fk_pay_sub FOREIGN KEY (subscription_id) REFERENCES analytics.fct_subscriptions(subscription_id);

ALTER TABLE analytics.fct_support 
    ADD CONSTRAINT fk_sup_cust FOREIGN KEY (customer_id) REFERENCES analytics.dim_customers(customer_id);


-- 6. BUILD THE EXECUTIVE KPI VIEW
CREATE OR REPLACE VIEW analytics.vw_executive_mrr_churn AS 
WITH base_metrics AS (
    SELECT 
        c.segment,
        c.industry,
        p.plan_name,
        s.status,
        p.monthly_price,
        c.health_score,
        c.risk_category
    FROM analytics.fct_subscriptions s
    INNER JOIN analytics.dim_customers c ON s.customer_id = c.customer_id
    INNER JOIN analytics.dim_plans p ON s.plan_id = p.plan_id
)
SELECT 
    segment,
    COUNT(*) AS total_subscriptions,
    SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END) AS active_logos,
    SUM(CASE WHEN status = 'Churned' THEN 1 ELSE 0 END) AS churned_logos,
    ROUND(SUM(CASE WHEN status = 'Churned' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS logo_churn_pct,
    SUM(CASE WHEN status = 'Active' THEN monthly_price ELSE 0 END) AS active_mrr,
    SUM(CASE WHEN status = 'Churned' THEN monthly_price ELSE 0 END) AS churned_mrr,
    SUM(CASE WHEN status = 'Active' AND risk_category = 'Critical Risk' THEN monthly_price ELSE 0 END) AS critical_risk_mrr,
    ROUND(AVG(health_score)::NUMERIC, 1) AS avg_health_score
FROM base_metrics
GROUP BY segment
ORDER BY active_mrr DESC;