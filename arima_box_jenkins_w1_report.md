# Time Series Analysis of Truck Manufacturing Defects W1

- **Project root:** `/home/rstudio/project`
- **Data source:** `data/truck_manufacturing_defects_w1.csv`
- **Book comparison source:** `data/w1_book_acf_pacf.csv`
- **Total observations:** 45
- **80:20 split:** 36 modelling observations and 9 forecast test observations

## PDF Method Alignment

The workflow below follows the ARIMA Box-Jenkins notes in `docs/ARIMA_Box-Jenkins.pdf`:

- **Stationary in variance:** check from the time-series plot and variance behavior. The PDF notes that variance non-stationarity is not visible in the correlogram; use Box-Cox if variance is not stable.
- **Stationary in mean:** check the ACF/PACF pattern and the ADF test. ACF that dies down quickly and enters the +/- 2/sqrt(n) band supports stationarity in mean; ACF that starts near 1 and decays slowly suggests non-stationarity in mean.
- **ADF decision:** H0 means unit root / not stationary. Reject H0 when the ADF statistic is below the critical value or p-value < alpha. If H0 is not rejected, apply differencing and test again.
- **Model identification:** after the stationarity treatment, use ACF/PACF to form candidate ARIMA orders, then estimate parameters and compare candidate models.

## Analysis 1: Full Data Modelling (45 Entries)

- **Modelling observations:** 45, periods 1-45
- **Forecast type:** future forecast after the last observed period; no held-out accuracy metrics.

### 1. Time Series Plot

![Analysis 1: Full Data Modelling (45 Entries) time series plot](plots_rstudio/w1/full_data_01_timeseries.png)

### 2. Stationarity Check Following the Box-Jenkins Flow

The diagram below evaluates stationarity before and after differencing using trend and variance line tools alongside ACF and PACF correlograms, aligned with the Box-Jenkins methodology in `docs/ARIMA_Box-Jenkins.pdf`.

![Analysis 1: Full Data Modelling (45 Entries) stationarity evaluation diagram](plots_rstudio/w1/full_data_02_stationarity_decision_diagram.png)

#### A. Stationary in Variance?

- **H0:** variance in the first and second half is equal, so data is stationary in variance.
- **H1:** variance is different, so data is not stationary in variance.
- **Variance first half:** 0.3161
- **Variance second half:** 0.1869
- **F statistic:** 1.6911
- **p-value:** 0.2291
- **Alpha:** 0.05
- **Decision rule:** reject H0 if p-value < alpha.
- **Decision:** Fail to reject H0
- **Conclusion:** modelling series is stationary in variance.
- **Treatment:** No Box-Cox transformation needed.

**ACF/PACF note for variance:** ACF and PACF do not directly test stationarity in variance. They are used below for mean-stationarity and model-order diagnosis. Variance stationarity is decided here from the variance comparison and time-series plot.

![Analysis 1: Full Data Modelling (45 Entries) variance stationarity check](plots_rstudio/w1/full_data_02_variance_stationarity_check.png)

#### B. Stationary in Mean?

Tested after the variance step using both ACF/PACF behavior and the ADF H0 mechanism.

**ACF/PACF decision before differencing:**

- **Significance threshold:** +/- 0.2981, calculated as +/- 2/sqrt(n).
- **ACF lag 1:** 0.4288
- **PACF lag 1:** 0.4288
- **Significant ACF lags:** 1
- **Significant PACF lags:** 1
- **ACF/PACF mean-stationarity decision:** stationary in mean
- **Reason:** ACF does not decay slowly from a value near 1; significant lags die out quickly.

**ADF decision:**

- **ADF test function:** `tseries::adf.test()`
- **H0:** gamma = 0, series has a unit root, so data is not stationary in mean.
- **H1:** gamma < 0, series has no unit root, so data is stationary in mean.
- **Initial ADF statistic before differencing:** -3.2768
- **Initial selected lag parameter:** 2
- **Initial ADF p-value:** 0.0875
- **Final ADF statistic:** -5.2165
- **Final selected lag parameter:** 2
- **Final ADF p-value:** 0.0100
- **Alpha:** 0.05
- **Decision rule:** reject H0 if p-value < alpha.
- **Decision:** Reject H0
- **Reason:** p-value (0.0100) < alpha (0.05).
- **Conclusion:** modelling series is stationary in mean at 5% significance level.
- **Treatment:** Differencing applied with d = 1.

**Alignment check:**

- **Initial ACF/PACF vs initial ADF:** not aligned.
- **Final ACF/PACF decision after treatment:** stationary in mean
- **Final ADF decision after treatment:** stationary in mean
- **Final ACF/PACF vs final ADF:** aligned.

![Analysis 1: Full Data Modelling (45 Entries) mean stationarity check](plots_rstudio/w1/full_data_03_mean_stationarity_check.png)

#### C. Non-Stationarity Factor Diagnosis

- **Variance factor:** stationary, no Box-Cox needed.
- **Mean factor:** conflicting initial evidence: ACF/PACF indicates stationary in mean, while ADF indicates not stationary in mean; the computational workflow follows the ADF treatment path.
- **Final status:** series is ready for ACF/PACF identification.

#### D. Model Identification (ACF and PACF)

![Analysis 1: Full Data Modelling (45 Entries) ACF and PACF](plots_rstudio/w1/full_data_04_acf_pacf_stationary.png)

- **Significance threshold:** +/- 0.3015, calculated as +/- 2/sqrt(n).
- **Significant ACF lags:** 1
- **Significant PACF lags:** 1
- **Rule-based diagnosis:** Both ACF and PACF have significant lag(s); compare small AR/ARMA candidates with AIC.
- **p range from PACF:** 0..1
- **q range from ACF:** 0..1
- **Candidate from ACF/PACF:** ARIMA(p,1,q), p = 0..1, q = 0..1
- **Candidate estimation rule:** estimate the full p/q grid inside the ACF/PACF-derived range, then select by AIC and validate with residual diagnostics.

### 3. Parameter Estimation and Model Selection

Estimated on variance-adjusted series with `d = 1`.

**Candidate orders estimated:**

```text
  p d q
1 0 1 0
2 1 1 0
3 0 1 1
4 1 1 1
```

**AR(p) lag possibilities:**

The table below estimates pure autoregressive alternatives `ARIMA(p,d,0)` for several lag lengths, using the same differencing order selected in the stationarity step.

```text
         model ar_lags      aic log_likelihood
1 ARIMA(1,1,0)    1..1 69.90138      -32.95069
2 ARIMA(2,1,0)    1..2 70.38740      -32.19370
3 ARIMA(3,1,0)    1..3 71.78151      -31.89075
4 ARIMA(0,1,0)    none 73.51215      -35.75608
5 ARIMA(4,1,0)    1..4 73.76992      -31.88496
6 ARIMA(5,1,0)    1..5 74.74897      -31.37448
7 ARIMA(6,1,0)    1..6 76.54294      -31.27147
```

**Combined model comparison for final decision:**

This table combines the ACF/PACF candidate grid with the extra AR(p) lag possibilities, then evaluates IIDN for every fitted model.

```text
  fit_index        model      aic log_likelihood ljung_box_p   shapiro_p  iidn_score mean_residual
1         3 ARIMA(0,1,1) 67.78699      -31.89350   0.7733705 0.064988657 0.064988657    0.02238482
2         2 ARIMA(1,1,0) 69.90138      -32.95069   0.6642281 0.068253878 0.068253878    0.01826677
3         5 ARIMA(2,1,0) 70.38740      -32.19370   0.6687429 0.106425133 0.106425133    0.02045447
4         6 ARIMA(3,1,0) 71.78151      -31.89075   0.5806585 0.068001721 0.068001721    0.02218008
5         1 ARIMA(0,1,0) 73.51215      -35.75608   0.2634634 0.056476680 0.056476680    0.01424889
6         7 ARIMA(4,1,0) 73.76992      -31.88496   0.4751621 0.073243089 0.073243089    0.02209054
7         4 ARIMA(1,1,1) 66.42686      -30.21343   0.7051641 0.002159731 0.002159731   -0.01799832
8         8 ARIMA(5,1,0) 74.74897      -31.37448   0.4306342 0.025852793 0.025852793    0.02109773
9         9 ARIMA(6,1,0) 76.54294      -31.27147   0.3521046 0.041736514 0.041736514    0.02148119
  variance_residual iidn_pass    iidn_decision selection_group
1         0.2475043      TRUE Pass IIDN checks       IIDN pass
2         0.2607291      TRUE Pass IIDN checks       IIDN pass
3         0.2514203      TRUE Pass IIDN checks       IIDN pass
4         0.2476166      TRUE Pass IIDN checks       IIDN pass
5         0.2972151      TRUE Pass IIDN checks       IIDN pass
6         0.2475502      TRUE Pass IIDN checks       IIDN pass
7         0.2164157     FALSE Fail IIDN checks       IIDN fail
8         0.2411539     FALSE Fail IIDN checks       IIDN fail
9         0.2399182     FALSE Fail IIDN checks       IIDN fail
                                                                                   residual_plot
1 plots_rstudio/w1/full_data_candidate_model_diagnostics/1_ARIMA_0_1_1__residual_diagnostics.png
2 plots_rstudio/w1/full_data_candidate_model_diagnostics/2_ARIMA_1_1_0__residual_diagnostics.png
3 plots_rstudio/w1/full_data_candidate_model_diagnostics/3_ARIMA_2_1_0__residual_diagnostics.png
4 plots_rstudio/w1/full_data_candidate_model_diagnostics/4_ARIMA_3_1_0__residual_diagnostics.png
5 plots_rstudio/w1/full_data_candidate_model_diagnostics/5_ARIMA_0_1_0__residual_diagnostics.png
6 plots_rstudio/w1/full_data_candidate_model_diagnostics/6_ARIMA_4_1_0__residual_diagnostics.png
7 plots_rstudio/w1/full_data_candidate_model_diagnostics/7_ARIMA_1_1_1__residual_diagnostics.png
8 plots_rstudio/w1/full_data_candidate_model_diagnostics/8_ARIMA_5_1_0__residual_diagnostics.png
9 plots_rstudio/w1/full_data_candidate_model_diagnostics/9_ARIMA_6_1_0__residual_diagnostics.png
```

**Model comparison plot:**

![Analysis 1: Full Data Modelling (45 Entries) model IIDN comparison](plots_rstudio/w1/full_data_05_model_iidn_comparison.png)

**Selected decision model:** `ARIMA(0,1,1)`

- **Selection rule:** evaluate IIDN for every candidate model first, then choose the lowest AIC among models that pass IIDN checks. If no candidate passes IIDN, choose the lowest-AIC fallback and document the diagnostic risk.
- **Selection result:** Selected as the lowest-AIC model among candidates that pass IIDN checks.

**Final ARIMA model equation:**

General ARIMA form:

$$
\phi(B) (1 - B)^d Z_t = \theta_0 + \theta(B) a_t
$$

B: operator backshift (`BZ_t = Z_{t-1}`) - `a_t`: galat white noise - `theta_0`: konstanta.

Estimated model form:

$$
(1)(1 - B)^{1} Z_t = (1 - 0.4847B^{1})a_t
$$

- **Decision model:** select `ARIMA(0,1,1)`. Selected as the lowest-AIC model among candidates that pass IIDN checks.
- **Equation note:** MA signs follow the R forecast::Arima convention, so MA terms appear as plus/minus the estimated ma coefficient on the right side.

**Selected model coefficients:**

```text
  parameter   estimate std_error   z_value     p_value
1       ma1 -0.4847062 0.1682835 -2.880295 0.003973027
```

### 4. Diagnostic Checking IIDN

![Analysis 1: Full Data Modelling (45 Entries) residual diagnostics](plots_rstudio/w1/full_data_05_iidn_diagnostic_checking.png)

- **Mean residual:** 0.022385
- **Residual variance:** 0.247504
- **Independence test, Ljung-Box lag 8 p-value:** 0.6990
- **Normality test, Shapiro-Wilk p-value:** 0.0650
- **IIDN interpretation:** independent if Ljung-Box p-value > 0.05; normally distributed if Shapiro-Wilk p-value > 0.05; identically distributed is checked visually from residual plot and stable residual spread.

### 5. Forecasting

![Analysis 1: Full Data Modelling (45 Entries) forecast](plots_rstudio/w1/full_data_06_forecast.png)

- **Forecast model:** `ARIMA(0,1,1)`
- **Forecast horizon:** 9 periods
- **Accuracy metrics:** not available because all observations are used for modelling.
- **Forecast CSV:** `data/truck_manufacturing_defects_w1_full_data_forecast.csv`

**Forecast values:**

```text
  period forecast  lower_95 upper_95
1     46 1.775724 0.7883343 2.763114
2     47 1.775724 0.6649533 2.886495
3     48 1.775724 0.5539692 2.997479
4     49 1.775724 0.4522596 3.099189
5     50 1.775724 0.3578272 3.193621
6     51 1.775724 0.2693029 3.282146
7     52 1.775724 0.1856996 3.365749
8     53 1.775724 0.1062777 3.445171
9     54 1.775724 0.0304664 3.520982
```

## Analysis 2: 80:20 Split Modelling and Forecast Test

- **Modelling observations:** 36, periods 1-36
- **Remaining forecast test observations:** 9, periods 37-45

### 1. Time Series Plot

![Analysis 2: 80:20 Split Modelling and Forecast Test time series plot](plots_rstudio/w1/split_80_20_01_timeseries.png)

### 2. Stationarity Check Following the Box-Jenkins Flow

The diagram below evaluates stationarity before and after differencing using trend and variance line tools alongside ACF and PACF correlograms, aligned with the Box-Jenkins methodology in `docs/ARIMA_Box-Jenkins.pdf`.

![Analysis 2: 80:20 Split Modelling and Forecast Test stationarity evaluation diagram](plots_rstudio/w1/split_80_20_02_stationarity_decision_diagram.png)

#### A. Stationary in Variance?

- **H0:** variance in the first and second half is equal, so data is stationary in variance.
- **H1:** variance is different, so data is not stationary in variance.
- **Variance first half:** 0.3329
- **Variance second half:** 0.2142
- **F statistic:** 1.5539
- **p-value:** 0.3725
- **Alpha:** 0.05
- **Decision rule:** reject H0 if p-value < alpha.
- **Decision:** Fail to reject H0
- **Conclusion:** modelling series is stationary in variance.
- **Treatment:** No Box-Cox transformation needed.

**ACF/PACF note for variance:** ACF and PACF do not directly test stationarity in variance. They are used below for mean-stationarity and model-order diagnosis. Variance stationarity is decided here from the variance comparison and time-series plot.

![Analysis 2: 80:20 Split Modelling and Forecast Test variance stationarity check](plots_rstudio/w1/split_80_20_02_variance_stationarity_check.png)

#### B. Stationary in Mean?

Tested after the variance step using both ACF/PACF behavior and the ADF H0 mechanism.

**ACF/PACF decision before differencing:**

- **Significance threshold:** +/- 0.3333, calculated as +/- 2/sqrt(n).
- **ACF lag 1:** 0.3985
- **PACF lag 1:** 0.3985
- **Significant ACF lags:** 1
- **Significant PACF lags:** 1
- **ACF/PACF mean-stationarity decision:** stationary in mean
- **Reason:** ACF does not decay slowly from a value near 1; significant lags die out quickly.

**ADF decision:**

- **ADF test function:** `tseries::adf.test()`
- **H0:** gamma = 0, series has a unit root, so data is not stationary in mean.
- **H1:** gamma < 0, series has no unit root, so data is stationary in mean.
- **Initial ADF statistic before differencing:** -2.3072
- **Initial selected lag parameter:** 2
- **Initial ADF p-value:** 0.4536
- **Final ADF statistic:** -4.3574
- **Final selected lag parameter:** 2
- **Final ADF p-value:** 0.0100
- **Alpha:** 0.05
- **Decision rule:** reject H0 if p-value < alpha.
- **Decision:** Reject H0
- **Reason:** p-value (0.0100) < alpha (0.05).
- **Conclusion:** modelling series is stationary in mean at 5% significance level.
- **Treatment:** Differencing applied with d = 1.

**Alignment check:**

- **Initial ACF/PACF vs initial ADF:** not aligned.
- **Final ACF/PACF decision after treatment:** stationary in mean
- **Final ADF decision after treatment:** stationary in mean
- **Final ACF/PACF vs final ADF:** aligned.

![Analysis 2: 80:20 Split Modelling and Forecast Test mean stationarity check](plots_rstudio/w1/split_80_20_03_mean_stationarity_check.png)

#### C. Non-Stationarity Factor Diagnosis

- **Variance factor:** stationary, no Box-Cox needed.
- **Mean factor:** conflicting initial evidence: ACF/PACF indicates stationary in mean, while ADF indicates not stationary in mean; the computational workflow follows the ADF treatment path.
- **Final status:** series is ready for ACF/PACF identification.

#### D. Model Identification (ACF and PACF)

![Analysis 2: 80:20 Split Modelling and Forecast Test ACF and PACF](plots_rstudio/w1/split_80_20_04_acf_pacf_stationary.png)

- **Significance threshold:** +/- 0.3381, calculated as +/- 2/sqrt(n).
- **Significant ACF lags:** none
- **Significant PACF lags:** none
- **Rule-based diagnosis:** No strict significant ACF/PACF spikes, but low-order lags are visible inside the confidence band; estimate a small p/q range and compare.
- **p range from PACF:** 0..2
- **q range from ACF:** 0..1
- **Candidate from ACF/PACF:** ARIMA(p,1,q), p = 0..2, q = 0..1
- **Candidate estimation rule:** estimate the full p/q grid inside the ACF/PACF-derived range, then select by AIC and validate with residual diagnostics.

### 3. Parameter Estimation and Model Selection

Estimated on variance-adjusted series with `d = 1`.

**Candidate orders estimated:**

```text
  p d q
1 0 1 0
2 1 1 0
3 2 1 0
4 0 1 1
5 1 1 1
6 2 1 1
```

**AR(p) lag possibilities:**

The table below estimates pure autoregressive alternatives `ARIMA(p,d,0)` for several lag lengths, using the same differencing order selected in the stationarity step.

```text
         model ar_lags      aic log_likelihood
1 ARIMA(2,1,0)    1..2 60.53371      -27.26686
2 ARIMA(1,1,0)    1..1 60.80500      -28.40250
3 ARIMA(0,1,0)    none 61.97676      -29.98838
4 ARIMA(3,1,0)    1..3 62.30867      -27.15433
5 ARIMA(4,1,0)    1..4 64.07091      -27.03546
6 ARIMA(5,1,0)    1..5 64.87373      -26.43686
7 ARIMA(6,1,0)    1..6 65.89830      -25.94915
```

**Combined model comparison for final decision:**

This table combines the ACF/PACF candidate grid with the extra AR(p) lag possibilities, then evaluates IIDN for every fitted model.

```text
   fit_index        model      aic log_likelihood ljung_box_p  shapiro_p iidn_score mean_residual
1          4 ARIMA(0,1,1) 58.83405      -27.41703   0.9295302 0.05601611 0.05601611    0.05669976
2          3 ARIMA(2,1,0) 60.53371      -27.26686   0.8866979 0.17661177 0.17661177    0.05528048
3          2 ARIMA(1,1,0) 60.80500      -28.40250   0.7564512 0.07709558 0.07709558    0.04733230
4          1 ARIMA(0,1,0) 61.97676      -29.98838   0.6242048 0.17735382 0.17735382    0.04753333
5          7 ARIMA(3,1,0) 62.30867      -27.15433   0.8464036 0.09025739 0.09025739    0.05769663
6          6 ARIMA(2,1,1) 62.38041      -27.19021   0.8420645 0.10168305 0.10168305    0.05775107
7          8 ARIMA(4,1,0) 64.07091      -27.03546   0.7714479 0.09099391 0.09099391    0.05515885
8         10 ARIMA(6,1,0) 65.89830      -25.94915   0.5789254 0.06443714 0.06443714    0.05107584
9          5 ARIMA(1,1,1) 59.38065      -26.69033   0.8467778 0.01260808 0.01260808    0.02319700
10         9 ARIMA(5,1,0) 64.87373      -26.43686   0.6558984 0.03707032 0.03707032    0.05942094
   variance_residual iidn_pass    iidn_decision selection_group
1          0.2750574      TRUE Pass IIDN checks       IIDN pass
2          0.2728647      TRUE Pass IIDN checks       IIDN pass
3          0.2934386      TRUE Pass IIDN checks       IIDN pass
4          0.3225704      TRUE Pass IIDN checks       IIDN pass
5          0.2706831      TRUE Pass IIDN checks       IIDN pass
6          0.2712959      TRUE Pass IIDN checks       IIDN pass
7          0.2686956      TRUE Pass IIDN checks       IIDN pass
8          0.2464394      TRUE Pass IIDN checks       IIDN pass
9          0.2496986     FALSE Fail IIDN checks       IIDN fail
10         0.2556346     FALSE Fail IIDN checks       IIDN fail
                                                                                       residual_plot
1   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/1_ARIMA_0_1_1__residual_diagnostics.png
2   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/2_ARIMA_2_1_0__residual_diagnostics.png
3   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/3_ARIMA_1_1_0__residual_diagnostics.png
4   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/4_ARIMA_0_1_0__residual_diagnostics.png
5   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/5_ARIMA_3_1_0__residual_diagnostics.png
6   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/6_ARIMA_2_1_1__residual_diagnostics.png
7   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/7_ARIMA_4_1_0__residual_diagnostics.png
8   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/8_ARIMA_6_1_0__residual_diagnostics.png
9   plots_rstudio/w1/split_80_20_candidate_model_diagnostics/9_ARIMA_1_1_1__residual_diagnostics.png
10 plots_rstudio/w1/split_80_20_candidate_model_diagnostics/10_ARIMA_5_1_0__residual_diagnostics.png
```

**Model comparison plot:**

![Analysis 2: 80:20 Split Modelling and Forecast Test model IIDN comparison](plots_rstudio/w1/split_80_20_05_model_iidn_comparison.png)

**Selected decision model:** `ARIMA(0,1,1)`

- **Selection rule:** evaluate IIDN for every candidate model first, then choose the lowest AIC among models that pass IIDN checks. If no candidate passes IIDN, choose the lowest-AIC fallback and document the diagnostic risk.
- **Selection result:** Selected as the lowest-AIC model among candidates that pass IIDN checks.

**Final ARIMA model equation:**

General ARIMA form:

$$
\phi(B) (1 - B)^d Z_t = \theta_0 + \theta(B) a_t
$$

B: operator backshift (`BZ_t = Z_{t-1}`) - `a_t`: galat white noise - `theta_0`: konstanta.

Estimated model form:

$$
(1)(1 - B)^{1} Z_t = (1 - 0.4843B^{1})a_t
$$

- **Decision model:** select `ARIMA(0,1,1)`. Selected as the lowest-AIC model among candidates that pass IIDN checks.
- **Equation note:** MA signs follow the R forecast::Arima convention, so MA terms appear as plus/minus the estimated ma coefficient on the right side.

**Selected model coefficients:**

```text
  parameter   estimate std_error  z_value     p_value
1       ma1 -0.4842679 0.1843573 -2.62679 0.008619462
```

### 4. Diagnostic Checking IIDN

![Analysis 2: 80:20 Split Modelling and Forecast Test residual diagnostics](plots_rstudio/w1/split_80_20_05_iidn_diagnostic_checking.png)

- **Mean residual:** 0.056700
- **Residual variance:** 0.275057
- **Independence test, Ljung-Box lag 6 p-value:** 0.8453
- **Normality test, Shapiro-Wilk p-value:** 0.0560
- **IIDN interpretation:** independent if Ljung-Box p-value > 0.05; normally distributed if Shapiro-Wilk p-value > 0.05; identically distributed is checked visually from residual plot and stable residual spread.

### 5. Forecasting

![Analysis 2: 80:20 Split Modelling and Forecast Test forecast](plots_rstudio/w1/split_80_20_06_forecast.png)

- **Forecast model:** `ARIMA(0,1,1)`
- **Forecast horizon:** 9 periods
- **MAE:** 0.7270
- **RMSE:** 0.7669
- **MAPE:** 49.96%
- **Forecast CSV:** `data/truck_manufacturing_defects_w1_split_forecast.csv`

**Forecast values:**

```text
  period actual forecast  lower_95 upper_95      error absolute_error absolute_percentage_error
1     37   1.77 2.309222 1.2600248 3.358420 -0.5392223      0.5392223                  30.46454
2     38   1.61 2.309222 1.1287098 3.489735 -0.6992223      0.6992223                  43.42996
3     39   1.25 2.309222 1.0106060 3.607839 -1.0592223      1.0592223                  84.73778
4     40   1.15 2.309222 0.9023824 3.716062 -1.1592223      1.1592223                 100.80194
5     41   1.37 2.309222 0.8019091 3.816535 -0.9392223      0.9392223                  68.55637
6     42   1.79 2.309222 0.7077269 3.910718 -0.5192223      0.5192223                  29.00683
7     43   1.68 2.309222 0.6187839 3.999661 -0.6292223      0.6292223                  37.45371
8     44   1.78 2.309222 0.5342924 4.084152 -0.5292223      0.5292223                  29.73159
9     45   1.84 2.309222 0.4536440 4.164801 -0.4692223      0.4692223                  25.50121
```

## Comparison with the Original Book Analysis

The original W1 example in the book uses the same 45 daily observations and identifies the series from the time-series plot plus the raw ACF/PACF pattern.

### Book Reference Result

- The book describes W1 as having stationary constant mean and variance.
- The book's ACF decays gradually.
- The book's PACF has one main significant spike at lag 1.
- The book concludes that W1 is likely generated by an AR(1) process, i.e. `ARIMA(1,0,0)`.

Book ACF/PACF values and standard errors shown in the source are stored in `data/w1_book_acf_pacf.csv`.

The significance flags below use the rule `abs(estimate) > 2 * St.E.`.

```text
   lag book_acf book_acf_stderr book_pacf book_pacf_stderr book_acf_significant book_pacf_significant
1    1     0.43            0.15      0.43             0.15                 TRUE                  TRUE
2    2     0.26            0.15      0.09             0.15                FALSE                 FALSE
3    3     0.14            0.17      0.00             0.15                FALSE                 FALSE
4    4     0.08            0.18      0.00             0.15                FALSE                 FALSE
5    5    -0.09            0.19     -0.16             0.15                FALSE                 FALSE
6    6    -0.07            0.19      0.00             0.15                FALSE                 FALSE
7    7    -0.21            0.19     -0.18             0.15                FALSE                 FALSE
8    8    -0.11            0.19      0.07             0.15                FALSE                 FALSE
9    9    -0.05            0.19      0.05             0.15                FALSE                 FALSE
10  10    -0.01            0.19      0.01             0.15                FALSE                 FALSE
```

### Our Independent Analysis Result

- Our independent workflow applies formal variance testing and ADF testing with lag selection by AIC.
- Our full-data selected model is `ARIMA(0,1,1)`.
- Our 80:20 split selected model is `ARIMA(0,1,1)`.
- 80:20 split accuracy: MAE = 0.7270, RMSE = 0.7669, MAPE = 49.96%.

### Interpretation

The book's AR(1) conclusion is based on raw W1 ACF/PACF identification. Our independent procedure may select a different model because it first applies an ADF-based stationarity decision and then estimates candidates after any required treatment. This is the comparison point: the book gives the classical identification result, while our workflow documents what happens when the full Box-Jenkins decision path is applied computationally.

