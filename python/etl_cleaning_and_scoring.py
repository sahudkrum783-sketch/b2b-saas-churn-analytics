"""
PROJECT: B2B SaaS Churn Data Warehouse
FILE: etl_cleaning_and_scoring.py
DESCRIPTION: Extracts raw data from PostgreSQL, cleans structural anomalies, 
             engineers a 0-100 Customer Health Score, and loads into the analytics schema.
"""

import pandas as pd
from sqlalchemy import create_engine

# =============================================================================
# 1. DATABASE CONNECTION & EXTRACTION
# =============================================================================
# Update with your actual PostgreSQL credentials
DB_URI = 'postgresql://postgres:password@localhost:5432/saas_churn_dw'
engine = create_engine(DB_URI)

print("Extracting raw tables...")
customers = pd.read_sql("SELECT * FROM raw_staging.dim_customers", engine)
plans = pd.read_sql("SELECT * FROM raw_staging.dim_plans", engine)
subs = pd.read_sql("SELECT * FROM raw_staging.fct_subscriptions", engine)
payments = pd.read_sql("SELECT * FROM raw_staging.fct_payments", engine)
support = pd.read_sql("SELECT * FROM raw_staging.fct_support", engine)

# =============================================================================
# 2. DATA CLEANING & ANOMALY RESOLUTION
# =============================================================================
print("Cleaning string anomalies and time-travel dates...")

# Fix the broken plan foreign keys (stripping the trailing space from 'P_PRO ')
plans['plan_id'] = plans['plan_id'].str.strip()
subs['plan_id'] = subs['plan_id'].str.strip()
subs['customer_id'] = subs['customer_id'].str.strip()
customers['customer_id'] = customers['customer_id'].str.strip()

# Drop the 23 time-travel subscriptions (end_date before start_date)
subs['start_date'] = pd.to_datetime(subs['start_date'])
subs['end_date'] = pd.to_datetime(subs['end_date'])
invalid_dates = subs['end_date'] < subs['start_date']
subs = subs[~invalid_dates]

# Drop the 52 negative payments (impossible business logic)
payments = payments[payments['amount'] >= 0]

# =============================================================================
# 3. FEATURE ENGINEERING: CUSTOMER HEALTH SCORE
# =============================================================================
print("Engineering Customer Health Scores...")

# Start everyone with a perfect score of 100
customers['health_score'] = 100

# Penalty 1: Failed Payments (-20 points per failure)
# We map payments to customers via the subscriptions table
failed_payments = payments[payments['status'] == 'Failed']
failed_subs = pd.merge(failed_payments, subs[['subscription_id', 'customer_id']], on='subscription_id')
payment_penalties = failed_subs.groupby('customer_id').size() * 20

# Penalty 2: High/Critical Support Tickets (-15 points per ticket)
critical_tickets = support[support['priority'].isin(['HIGH', 'CRITICAL'])]
ticket_penalties = critical_tickets.groupby('customer_id').size() * 15

# Apply penalties to the customers table
customers['health_score'] = customers.apply(
    lambda row: row['health_score'] 
    - payment_penalties.get(row['customer_id'], 0) 
    - ticket_penalties.get(row['customer_id'], 0), 
    axis=1
)

# Floor the score at 0 so we don't have negative health scores
customers['health_score'] = customers['health_score'].clip(lower=0)

# Create the Risk Category segmentation
def assign_risk_category(score):
    if score >= 70:
        return 'Healthy'
    elif score >= 50:
        return 'At Risk'
    else:
        return 'Critical Risk'

customers['risk_category'] = customers['health_score'].apply(assign_risk_category)

# =============================================================================
# 4. LOAD TO ANALYTICS SCHEMA
# =============================================================================
print("Loading cleaned tables into the analytics schema...")

# We use if_exists='replace' here because the database constraints (PKs/FKs) 
# are managed independently by our 02_star_schema_build.sql script.
customers.to_sql('dim_customers', engine, schema='analytics', if_exists='replace', index=False)
plans.to_sql('dim_plans', engine, schema='analytics', if_exists='replace', index=False)
subs.to_sql('fct_subscriptions', engine, schema='analytics', if_exists='replace', index=False)
payments.to_sql('fct_payments', engine, schema='analytics', if_exists='replace', index=False)
support.to_sql('fct_support', engine, schema='analytics', if_exists='replace', index=False)

print("Pipeline execution complete. Ready for Star Schema lockdown.")