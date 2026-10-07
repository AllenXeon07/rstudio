suppressPackageStartupMessages({
  library(forecast)
  library(tseries)
  library(lmtest)
})

project_root <- if (dir.exists("/home/rstudio/project")) {
  "/home/rstudio/project"
} else {
  getwd()
}

data_path <- file.path(project_root, "data", "truck_manufacturing_defects_w1.csv")
book_acf_pacf_path <- file.path(project_root, "data", "w1_book_acf_pacf.csv")
output_dir <- file.path(project_root, "plots_rstudio")
report_path <- file.path(project_root, "arima_box_jenkins_w1_report.md")

split_forecast_path <- file.path(project_root, "data", "truck_manufacturing_defects_w1_split_forecast.csv")
full_forecast_path <- file.path(project_root, "data", "truck_manufacturing_defects_w1_full_data_forecast.csv")

if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

plot_write_test <- tempfile(tmpdir = output_dir)
can_write_plots <- dir.exists(output_dir) && file.create(plot_write_test)
if (can_write_plots) {
  unlink(plot_write_test)
} else {
  output_dir <- file.path(tempdir(), "arima_box_jenkins_w1_plots")
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }
}

if (!dir.exists(output_dir) || file.access(output_dir, 2) != 0) {
  stop("Cannot create a writable output directory. Last tried: ", output_dir)
}

coefficient_table <- function(fit) {
  ct <- tryCatch(lmtest::coeftest(fit), error = function(e) NULL)
  if (is.null(ct) || nrow(ct) == 0) {
    return(data.frame(note = "No AR, MA, or intercept coefficients estimated."))
  }

  data.frame(
    parameter = rownames(ct),
    estimate = as.numeric(ct[, 1]),
    std_error = as.numeric(ct[, 2]),
    z_value = as.numeric(ct[, 3]),
    p_value = as.numeric(ct[, 4]),
    row.names = NULL
  )
}

diagnostic_tests <- function(fit) {
  resid <- residuals(fit)
  lb_res <- tryCatch(
    checkresiduals(fit, plot = FALSE),
    error = function(e) {
      fitdf <- length(fit$coef)
      lb_lag <- min(10, length(resid) - fitdf - 1)
      Box.test(resid, lag = lb_lag, type = "Ljung-Box", fitdf = fitdf)
    }
  )
  shapiro_res <- shapiro.test(resid)

  list(
    residuals = resid,
    ljung_box = lb_res,
    shapiro = shapiro_res,
    lb_lag = as.numeric(lb_res$parameter),
    mean_residual = mean(resid),
    variance_residual = var(resid)
  )
}

box_cox_transform <- function(x, lambda) {
  if (abs(lambda) < 1e-8) {
    log(x)
  } else {
    (x^lambda - 1) / lambda
  }
}

inverse_box_cox <- function(x, lambda) {
  if (abs(lambda) < 1e-8) {
    exp(x)
  } else {
    (lambda * x + 1)^(1 / lambda)
  }
}

estimate_box_cox_lambda <- function(x) {
  as.numeric(forecast::BoxCox.lambda(x, method = "loglik"))
}

variance_stationarity_check <- function(x, alpha = 0.05) {
  values <- as.numeric(x)
  first_half <- values[seq_len(floor(length(values) / 2))]
  second_half <- values[(floor(length(values) / 2) + 1):length(values)]
  test <- var.test(first_half, second_half)
  reject_h0 <- test$p.value < alpha

  list(
    alpha = alpha,
    statistic = as.numeric(test$statistic),
    p_value = test$p.value,
    variance_first_half = var(first_half),
    variance_second_half = var(second_half),
    decision = if (reject_h0) "Reject H0" else "Fail to reject H0",
    reject_h0 = reject_h0,
    conclusion = if (reject_h0) "not stationary in variance" else "stationary in variance"
  )
}

adf_stationarity_check <- function(x, alpha = 0.05, k = NULL) {
  values <- as.numeric(x)
  if (is.null(k)) {
    k <- min(2, max(1, trunc((length(values) - 1)^(1/3))))
  }
  test <- tseries::adf.test(values, alternative = "stationary", k = k)
  statistic <- as.numeric(test$statistic)
  p_value <- test$p.value
  reject_h0 <- p_value < alpha

  list(
    alpha = alpha,
    statistic = statistic,
    p_value = p_value,
    selected_lag = as.numeric(test$parameter),
    reject_h0 = reject_h0,
    decision = if (reject_h0) "Reject H0" else "Fail to reject H0",
    conclusion = if (reject_h0) "stationary in mean" else "not stationary in mean",
    test = test
  )
}

safe_arima <- function(x, order) {
  tryCatch(
    forecast::Arima(x, order = order, method = "ML"),
    error = function(e) NULL
  )
}

format_lags <- function(lags) {
  if (length(lags) == 0) {
    "none"
  } else {
    paste(lags, collapse = ", ")
  }
}

derive_order_limit <- function(values, threshold, max_order = 2) {
  inspected_values <- values[seq_len(min(max_order, length(values)))]
  significant_lags <- which(abs(inspected_values) > threshold)

  if (length(significant_lags) > 0) {
    return(max(significant_lags))
  }

  visible_lags <- which(abs(inspected_values) > 0.5 * threshold)
  if (length(visible_lags) > 0) {
    return(max(visible_lags))
  }

  0
}

relative_path <- function(path) {
  normalized_root <- normalizePath(project_root, winslash = "/", mustWork = FALSE)
  normalized_path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  sub(paste0("^", normalized_root, "/?"), "", normalized_path)
}

write_image <- function(path, caption) {
  cat(sprintf("![%s](%s)\n\n", caption, relative_path(path)))
}

write_data_frame_block <- function(x) {
  cat("```text\n")
  cat(paste(capture.output(print(x)), collapse = "\n"))
  cat("\n```\n\n")
}

draw_stem_correlogram <- function(
  values,
  lag_max = 20,
  main_title,
  subtitle_text,
  is_acf = TRUE,
  col_bar = "#2563eb",
  col_line = "#ea580c"
) {
  n <- length(values)
  thresh <- 2 / sqrt(n)
  lag_limit <- min(lag_max, n - 1)
  if (is_acf) {
    cf_res <- forecast::Acf(values, lag.max = lag_limit, plot = FALSE)
    vals <- as.numeric(cf_res$acf)
  } else {
    cf_res <- forecast::Pacf(values, lag.max = lag_limit, plot = FALSE)
    vals <- as.numeric(cf_res$acf)
  }
  lags <- seq_along(vals)

  ylim_r <- range(c(vals, -thresh * 1.35, thresh * 1.35, -0.45, 0.65))
  plot(
    lags, vals, type = "n",
    xlim = c(0.4, lag_limit + 0.6), ylim = ylim_r,
    xlab = "Lag", ylab = if (is_acf) "Autocorrelation (ACF)" else "Partial Autocorrelation (PACF)",
    main = "", xaxt = "n"
  )
  mtext(main_title, side = 3, line = 1.4, font = 2, cex = 1.0, col = "#0f172a")
  mtext(subtitle_text, side = 3, line = 0.2, font = 3, cex = 0.78, col = "#64748b")

  at_ticks <- c(1, 5, 10, 15, 20)[c(1, 5, 10, 15, 20) <= lag_limit]
  axis(1, at = at_ticks, col.axis = "#334155")
  grid(col = "#e2e8f0", lty = 1)
  abline(h = 0, col = "#64748b", lwd = 1.3)
  abline(h = c(-thresh, thresh), col = col_line, lty = 2, lwd = 1.6)

  segments(lags, 0, lags, vals, lwd = 3.8, col = col_bar)
  points(lags, vals, pch = 16, col = col_bar, cex = 1.05)

  legend(
    "topright",
    legend = sprintf("Batas Signifikansi ±2/√n (±%.3f)", thresh),
    col = col_line, lty = 2, lwd = 1.6, bty = "o", box.col = "#cbd5e1", bg = "#ffffff", cex = 0.78
  )
}

draw_stationarity_decision_diagram <- function(
  path,
  label,
  raw_ts,
  stationary_ts,
  variance_result,
  variance_treatment,
  mean_acf_pacf_before_difference,
  mean_acf_pacf_final,
  adf_result_before_difference,
  adf_result,
  mean_treatment,
  difference_order
) {
  png(path, width = 1450, height = 880, res = 100)
  par(
    oma = c(3.2, 1.2, 4.2, 1.2),
    mar = c(4.2, 4.2, 3.6, 1.5),
    mfrow = c(2, 3),
    bg = "#f8fafc"
  )

  # --- ROW 1: SEBELUM DIFFERENCING ---
  y_raw <- as.numeric(raw_ts)
  time_raw <- if (!is.null(time(raw_ts))) as.numeric(time(raw_ts)) else seq_along(y_raw)
  m_raw <- mean(y_raw)
  s_raw <- sd(y_raw)
  reg_raw <- lm(y_raw ~ time_raw)
  trend_slope_raw <- coef(reg_raw)[2]

  y_min_raw <- min(y_raw, m_raw - 2 * s_raw)
  y_max_raw <- max(y_raw, m_raw + 2 * s_raw)
  y_range_raw <- y_max_raw - y_min_raw

  plot(
    time_raw, y_raw, type = "o", pch = 16, col = "#2563eb", cex = 0.9,
    xlab = "Period", ylab = "Value (Zt)",
    main = "",
    ylim = c(y_min_raw - 0.08 * y_range_raw, y_max_raw + 0.35 * y_range_raw)
  )
  mtext("Sebelum: Time Series Level & Line Tools", side = 3, line = 1.4, font = 2, cex = 1.0, col = "#0f172a")
  mtext("Trend line (merah), Mean (abu-abu), Batas varians ±2σ (oranye)", side = 3, line = 0.2, font = 3, cex = 0.78, col = "#64748b")
  grid(col = "#e2e8f0", lty = 1)
  abline(reg_raw, col = "#dc2626", lwd = 2.4)
  abline(h = m_raw, col = "#475569", lty = 2, lwd = 1.8)
  abline(h = c(m_raw - 2 * s_raw, m_raw + 2 * s_raw), col = "#ea580c", lty = 3, lwd = 1.6)

  x_start_raw <- min(time_raw)
  x_span_raw <- diff(range(time_raw))
  rect(
    xleft = x_start_raw - 0.02 * x_span_raw,
    ybottom = y_max_raw + 0.16 * y_range_raw,
    xright = x_start_raw + 0.38 * x_span_raw,
    ytop = y_max_raw + 0.33 * y_range_raw,
    col = if (adf_result_before_difference$reject_h0) "#dcfce7" else "#fee2e2",
    border = if (adf_result_before_difference$reject_h0) "#22c55e" else "#ef4444",
    lwd = 1.5
  )
  status_text_raw <- if (adf_result_before_difference$reject_h0) {
    sprintf("STATUS: STASIONER MEAN\nADF τ = %.2f, p = %.4f", adf_result_before_difference$statistic, adf_result_before_difference$p_value)
  } else {
    sprintf("STATUS: TIDAK STASIONER\nADF τ = %.2f, p = %.4f", adf_result_before_difference$statistic, adf_result_before_difference$p_value)
  }
  text(
    x = x_start_raw + 0.19 * x_span_raw,
    y = y_max_raw + 0.245 * y_range_raw,
    labels = status_text_raw,
    col = if (adf_result_before_difference$reject_h0) "#166534" else "#991b1b",
    font = 2, cex = 0.72
  )

  legend(
    "topright",
    legend = c(
      "Observed Zt",
      sprintf("Trend (slope = %.3f)", trend_slope_raw),
      sprintf("Mean (μ = %.2f)", m_raw),
      "Batas Varians ±2σ"
    ),
    col = c("#2563eb", "#dc2626", "#475569", "#ea580c"),
    lty = c(1, 1, 2, 3), pch = c(16, NA, NA, NA), lwd = c(1.5, 2.4, 1.8, 1.6),
    bty = "o", box.col = "#cbd5e1", bg = "#ffffff", cex = 0.73
  )

  draw_stem_correlogram(
    y_raw,
    main_title = "Sebelum: Correlogram ACF",
    subtitle_text = sprintf("Lag 1 = %.2f; evaluasi penurunan menuju batas ±2/√n", mean_acf_pacf_before_difference$acf_lag_1),
    is_acf = TRUE, col_bar = "#2563eb", col_line = "#ea580c"
  )

  draw_stem_correlogram(
    y_raw,
    main_title = "Sebelum: Correlogram PACF",
    subtitle_text = sprintf("Lag 1 = %.2f; cut-off teramati sebelum differencing", mean_acf_pacf_before_difference$pacf_lag_1),
    is_acf = FALSE, col_bar = "#2563eb", col_line = "#ea580c"
  )

  # --- ROW 2: SESUDAH DIFFERENCING ---
  y_stat <- as.numeric(stationary_ts)
  time_stat <- if (!is.null(time(stationary_ts))) as.numeric(time(stationary_ts)) else seq_along(y_stat)
  m_stat <- mean(y_stat)
  s_stat <- sd(y_stat)
  reg_stat <- lm(y_stat ~ time_stat)
  trend_slope_stat <- coef(reg_stat)[2]

  y_min_stat <- min(y_stat, m_stat - 2 * s_stat)
  y_max_stat <- max(y_stat, m_stat + 2 * s_stat)
  y_range_stat <- y_max_stat - y_min_stat

  row2_title <- if (difference_order > 0) {
    sprintf("Sesudah: Differenced Series (d = %s) & Line Tools", difference_order)
  } else {
    "Sesudah: Stationary Series (d = 0) & Line Tools"
  }
  row2_subtitle <- if (difference_order > 0) {
    "Tren tereleminasi (garis tren datar); berfluktuasi stabil di sekitar nol"
  } else {
    "Data berfluktuasi stabil di sekitar satu nilai rata-rata konstan"
  }

  plot(
    time_stat, y_stat, type = "o", pch = 16, col = "#059669", cex = 0.9,
    xlab = "Period", ylab = if (difference_order > 0) sprintf("Differenced Wt (d = %s)", difference_order) else "Stationary Zt",
    main = "",
    ylim = c(y_min_stat - 0.08 * y_range_stat, y_max_stat + 0.35 * y_range_stat)
  )
  mtext(row2_title, side = 3, line = 1.4, font = 2, cex = 1.0, col = "#0f172a")
  mtext(row2_subtitle, side = 3, line = 0.2, font = 3, cex = 0.78, col = "#64748b")
  grid(col = "#e2e8f0", lty = 1)
  abline(reg_stat, col = "#16a34a", lwd = 2.4)
  abline(h = m_stat, col = "#475569", lty = 2, lwd = 1.8)
  abline(h = c(m_stat - 2 * s_stat, m_stat + 2 * s_stat), col = "#ea580c", lty = 3, lwd = 1.6)

  x_start_stat <- min(time_stat)
  x_span_stat <- diff(range(time_stat))
  rect(
    xleft = x_start_stat - 0.02 * x_span_stat,
    ybottom = y_max_stat + 0.16 * y_range_stat,
    xright = x_start_stat + 0.38 * x_span_stat,
    ytop = y_max_stat + 0.33 * y_range_stat,
    col = if (adf_result$reject_h0) "#dcfce7" else "#fee2e2",
    border = if (adf_result$reject_h0) "#22c55e" else "#ef4444",
    lwd = 1.5
  )
  status_text_stat <- if (adf_result$reject_h0) {
    sprintf("STATUS: STASIONER MEAN\nADF τ = %.2f, p = %.4f (Tolak H0)", adf_result$statistic, adf_result$p_value)
  } else {
    sprintf("STATUS: BELUM STASIONER\nADF τ = %.2f, p = %.4f", adf_result$statistic, adf_result$p_value)
  }
  text(
    x = x_start_stat + 0.19 * x_span_stat,
    y = y_max_stat + 0.245 * y_range_stat,
    labels = status_text_stat,
    col = if (adf_result$reject_h0) "#166534" else "#991b1b",
    font = 2, cex = 0.72
  )

  legend(
    "topright",
    legend = c(
      if (difference_order > 0) sprintf("Diff Series (d = %s)", difference_order) else "Stationary Series",
      sprintf("Trend (slope = %.3f)", trend_slope_stat),
      sprintf("Mean (μ = %.2f)", m_stat),
      "Batas Varians ±2σ"
    ),
    col = c("#059669", "#16a34a", "#475569", "#ea580c"),
    lty = c(1, 1, 2, 3), pch = c(16, NA, NA, NA), lwd = c(1.5, 2.4, 1.8, 1.6),
    bty = "o", box.col = "#cbd5e1", bg = "#ffffff", cex = 0.73
  )

  draw_stem_correlogram(
    y_stat,
    main_title = if (difference_order > 0) sprintf("Sesudah: Correlogram ACF (d = %s)", difference_order) else "Sesudah: Correlogram ACF",
    subtitle_text = "Autokorelasi langsung masuk ke dalam batas signifikansi ±2/√n",
    is_acf = TRUE, col_bar = "#059669", col_line = "#ea580c"
  )

  draw_stem_correlogram(
    y_stat,
    main_title = if (difference_order > 0) sprintf("Sesudah: Correlogram PACF (d = %s)", difference_order) else "Sesudah: Correlogram PACF",
    subtitle_text = "Autokorelasi parsial stabil di dalam batas signifikansi ±2/√n",
    is_acf = FALSE, col_bar = "#059669", col_line = "#ea580c"
  )

  mtext(
    paste(label, "- Evaluasi Stasioneritas & Penanganan Differencing"),
    side = 3, line = 2.0, outer = TRUE, cex = 1.35, font = 2, col = "#0f172a"
  )
  mtext(
    "Box-Jenkins: Line tools untuk deteksi tren & varians, diikuti evaluasi korelogram ACF/PACF sebelum dan sesudah differencing",
    side = 3, line = 0.5, outer = TRUE, cex = 0.95, col = "#475569"
  )

  footer_text <- sprintf(
    "Keputusan Box-Jenkins: Varians %s (F-test p = %.4f, %s). Mean %s setelah differencing d = %s (ADF %s). Siap identifikasi ARIMA.",
    variance_result$conclusion, variance_result$p_value, variance_treatment,
    adf_result$conclusion, difference_order, adf_result$decision
  )
  mtext(footer_text, side = 1, line = 1.2, outer = TRUE, cex = 0.88, font = 2, col = "#1e293b")

  dev.off()
}

diagnose_acf_pacf <- function(x, max_lag = 20) {
  values <- as.numeric(x)
  lag_limit <- min(max_lag, length(values) - 1)
  threshold <- 2 / sqrt(length(values))

  acf_values <- as.numeric(acf(values, lag.max = lag_limit, plot = FALSE)$acf)[-1]
  pacf_values <- as.numeric(pacf(values, lag.max = lag_limit, plot = FALSE)$acf)

  acf_lags <- seq_along(acf_values)
  pacf_lags <- seq_along(pacf_values)
  significant_acf_lags <- acf_lags[abs(acf_values) > threshold]
  significant_pacf_lags <- pacf_lags[abs(pacf_values) > threshold]
  p_range_max <- derive_order_limit(pacf_values, threshold)
  q_range_max <- derive_order_limit(acf_values, threshold)

  if (length(significant_acf_lags) == 0 && length(significant_pacf_lags) == 0) {
    if (p_range_max > 0 || q_range_max > 0) {
      diagnosis <- "No strict significant ACF/PACF spikes, but low-order lags are visible inside the confidence band; estimate a small p/q range and compare."
      candidate <- sprintf("ARIMA(p,d,q), p = 0..%s, q = 0..%s", p_range_max, q_range_max)
    } else {
      diagnosis <- "White-noise-like pattern: no significant ACF or PACF lags."
      candidate <- "ARIMA(0,d,0)"
    }
  } else if (length(significant_pacf_lags) > 0 && length(significant_acf_lags) == 0) {
    diagnosis <- "PACF has significant lag(s) while ACF has no significant cut-off; this supports an AR candidate."
    candidate <- sprintf("ARIMA(p,d,0), p = 0..%s", p_range_max)
  } else if (length(significant_acf_lags) > 0 && length(significant_pacf_lags) == 0) {
    diagnosis <- "ACF has significant lag(s) while PACF has no significant cut-off; this supports an MA candidate."
    candidate <- sprintf("ARIMA(0,d,q), q = 0..%s", q_range_max)
  } else {
    diagnosis <- "Both ACF and PACF have significant lag(s); compare small AR/ARMA candidates with AIC."
    candidate <- sprintf(
      "ARIMA(p,d,q), p = 0..%s, q = 0..%s",
      p_range_max,
      q_range_max
    )
  }

  list(
    threshold = threshold,
    significant_acf_lags = significant_acf_lags,
    significant_pacf_lags = significant_pacf_lags,
    p_range_max = p_range_max,
    q_range_max = q_range_max,
    diagnosis = diagnosis,
    candidate = candidate
  )
}

diagnose_mean_stationarity_from_acf_pacf <- function(x, max_lag = 20) {
  values <- as.numeric(x)
  lag_limit <- min(max_lag, length(values) - 1)
  threshold <- 2 / sqrt(length(values))
  acf_values <- as.numeric(acf(values, lag.max = lag_limit, plot = FALSE)$acf)[-1]
  pacf_values <- as.numeric(pacf(values, lag.max = lag_limit, plot = FALSE)$acf)
  acf_lags <- seq_along(acf_values)
  pacf_lags <- seq_along(pacf_values)
  significant_acf_lags <- acf_lags[abs(acf_values) > threshold]
  significant_pacf_lags <- pacf_lags[abs(pacf_values) > threshold]
  acf_lag_1 <- acf_values[1]
  pacf_lag_1 <- pacf_values[1]
  slow_acf_decay <- abs(acf_lag_1) >= 0.8 ||
    (length(significant_acf_lags) >= 5 && max(significant_acf_lags) >= 5)
  stationary <- !slow_acf_decay

  list(
    threshold = threshold,
    acf_lag_1 = acf_lag_1,
    pacf_lag_1 = pacf_lag_1,
    significant_acf_lags = significant_acf_lags,
    significant_pacf_lags = significant_pacf_lags,
    slow_acf_decay = slow_acf_decay,
    stationary = stationary,
    decision = if (stationary) "stationary in mean" else "not stationary in mean",
    reason = if (stationary) {
      "ACF does not decay slowly from a value near 1; significant lags die out quickly."
    } else {
      "ACF starts near 1 or remains significant for many lags, indicating slow decay."
    }
  )
}

generate_candidate_orders <- function(acf_pacf_diagnosis, difference_order) {
  expand.grid(
    p = 0:acf_pacf_diagnosis$p_range_max,
    d = difference_order,
    q = 0:acf_pacf_diagnosis$q_range_max
  )
}

run_box_jenkins_analysis <- function(label, model_data, test_data = NULL, prefix, forecast_path, future_horizon = 9) {
  model_ts <- ts(model_data$value, start = min(model_data$period), frequency = 1)
  has_test_data <- !is.null(test_data) && nrow(test_data) > 0

  plot_path <- list(
    time_series = file.path(output_dir, paste0(prefix, "_01_timeseries.png")),
    stationarity_decision = file.path(output_dir, paste0(prefix, "_02_stationarity_decision_diagram.png")),
    variance = file.path(output_dir, paste0(prefix, "_02_variance_stationarity_check.png")),
    mean = file.path(output_dir, paste0(prefix, "_03_mean_stationarity_check.png")),
    acf_pacf = file.path(output_dir, paste0(prefix, "_04_acf_pacf_stationary.png")),
    diagnostics = file.path(output_dir, paste0(prefix, "_05_iidn_diagnostic_checking.png")),
    forecast = file.path(output_dir, paste0(prefix, "_06_forecast.png"))
  )

  png(plot_path$time_series, width = 900, height = 550)
  plot(
    model_data$period,
    model_data$value,
    type = "o",
    pch = 16,
    col = "#1f77b4",
    xlim = range(c(model_data$period, if (has_test_data) test_data$period else numeric(0))),
    ylim = range(c(model_data$value, if (has_test_data) test_data$value else numeric(0))),
    xlab = "Period",
    ylab = "Daily average number of defects",
    main = paste(label, "- Time Series Plot")
  )
  if (has_test_data) {
    lines(test_data$period, test_data$value, type = "o", pch = 16, col = "#d55e00")
    abline(v = max(model_data$period), lty = 3)
    legend(
      "topright",
      legend = c("Modelling data", "Remaining data"),
      col = c("#1f77b4", "#d55e00"),
      lty = 1,
      pch = 16,
      bty = "n"
    )
  }
  grid()
  dev.off()

  variance_result <- variance_stationarity_check(model_ts)
  lambda <- 1
  variance_adjusted_ts <- model_ts
  variance_treatment <- "No Box-Cox transformation needed."

  if (variance_result$reject_h0) {
    if (any(model_ts <= 0)) {
      variance_treatment <- "Box-Cox skipped because the modelling series contains non-positive values."
    } else {
      lambda <- estimate_box_cox_lambda(as.numeric(model_ts))
      variance_adjusted_ts <- ts(
        box_cox_transform(as.numeric(model_ts), lambda),
        start = start(model_ts),
        frequency = frequency(model_ts)
      )
      variance_treatment <- sprintf("Box-Cox transformation applied with lambda = %.2f.", lambda)
    }
  }

  adf_lag_strategy <- "Standard Augmented Dickey-Fuller test via tseries::adf.test() with p-value decision rule."
  mean_acf_pacf_before_difference <- diagnose_mean_stationarity_from_acf_pacf(variance_adjusted_ts)
  adf_result_before_difference <- adf_stationarity_check(variance_adjusted_ts)
  mean_initially_stationary <- adf_result_before_difference$reject_h0
  difference_order <- 0
  stationary_ts <- variance_adjusted_ts
  adf_result <- adf_result_before_difference
  mean_treatment <- "No differencing needed."

  while (!adf_result$reject_h0 && difference_order < 2) {
    difference_order <- difference_order + 1
    stationary_ts <- diff(variance_adjusted_ts, differences = difference_order)
    adf_result <- adf_stationarity_check(stationary_ts)
    mean_treatment <- sprintf("Differencing applied with d = %s.", difference_order)
  }

  if (!adf_result$reject_h0) {
    mean_treatment <- paste(mean_treatment, "Series is still not stationary in mean after d = 2.")
  }
  mean_acf_pacf_final <- diagnose_mean_stationarity_from_acf_pacf(stationary_ts)
  initial_stationarity_alignment <- mean_acf_pacf_before_difference$stationary == adf_result_before_difference$reject_h0
  final_stationarity_alignment <- mean_acf_pacf_final$stationary == adf_result$reject_h0

  draw_stationarity_decision_diagram(
    path = plot_path$stationarity_decision,
    label = label,
    raw_ts = variance_adjusted_ts,
    stationary_ts = stationary_ts,
    variance_result = variance_result,
    variance_treatment = variance_treatment,
    mean_acf_pacf_before_difference = mean_acf_pacf_before_difference,
    mean_acf_pacf_final = mean_acf_pacf_final,
    adf_result_before_difference = adf_result_before_difference,
    adf_result = adf_result,
    mean_treatment = mean_treatment,
    difference_order = difference_order
  )

  png(plot_path$variance, width = 950, height = 560)
  y_v <- as.numeric(variance_adjusted_ts)
  t_v <- if (!is.null(time(variance_adjusted_ts))) as.numeric(time(variance_adjusted_ts)) else seq_along(y_v)
  m_v <- mean(y_v)
  s_v <- sd(y_v)
  split_idx <- floor(length(y_v) / 2)
  split_time <- t_v[split_idx] + 0.5
  plot(
    t_v, y_v,
    type = "o",
    pch = 16,
    col = "#2563eb",
    xlab = "Period",
    ylab = "Value",
    main = paste(label, "- Variance Stationarity Check & Line Tools"),
    ylim = range(c(y_v, m_v + 2.4 * s_v, m_v - 2.4 * s_v))
  )
  grid(col = "#e2e8f0")
  abline(h = m_v, col = "#475569", lty = 2, lwd = 1.8)
  abline(h = c(m_v - 2 * s_v, m_v + 2 * s_v), col = "#ea580c", lty = 3, lwd = 1.8)
  abline(v = split_time, col = "#94a3b8", lty = 4, lwd = 1.5)
  legend(
    "topright",
    legend = c(
      "Variance-adjusted series",
      sprintf("Mean line (μ = %.2f)", m_v),
      "Fluctuation bounds (±2σ)",
      sprintf("Split boundary (period %d)", split_idx),
      sprintf("F-test: stat = %.4f, p = %.4f (%s)", variance_result$statistic, variance_result$p_value, variance_result$decision)
    ),
    col = c("#2563eb", "#475569", "#ea580c", "#94a3b8", NA),
    lty = c(1, 2, 3, 4, NA),
    pch = c(16, NA, NA, NA, NA),
    lwd = c(1.5, 1.8, 1.8, 1.5, NA),
    bty = "o", box.col = "#cbd5e1", bg = "#ffffff", cex = 0.8
  )
  dev.off()

  png(plot_path$mean, width = 950, height = 560)
  y_m <- as.numeric(stationary_ts)
  t_m <- if (!is.null(time(stationary_ts))) as.numeric(time(stationary_ts)) else seq_along(y_m)
  m_m <- mean(y_m)
  s_m <- sd(y_m)
  reg_m <- lm(y_m ~ t_m)
  plot(
    t_m, y_m,
    type = "o",
    pch = 16,
    col = "#009e73",
    xlab = "Period",
    ylab = "Stationary series value",
    main = sprintf("%s - Mean Stationarity Check (d = %s) & Line Tools", label, difference_order),
    ylim = range(c(y_m, m_m + 2.4 * s_m, m_m - 2.4 * s_m))
  )
  grid(col = "#e2e8f0")
  abline(reg_m, col = "#15803d", lwd = 2.4)
  abline(h = m_m, col = "#475569", lty = 2, lwd = 1.8)
  abline(h = c(m_m - 2 * s_m, m_m + 2 * s_m), col = "#ea580c", lty = 3, lwd = 1.8)
  legend(
    "topright",
    legend = c(
      sprintf("Stationary series (d = %s)", difference_order),
      sprintf("Fitted trend line (slope = %.4f)", coef(reg_m)[2]),
      sprintf("Mean line (μ = %.2f)", m_m),
      "Fluctuation bounds (±2σ)",
      sprintf("ADF test: stat = %.4f, p = %.4f (%s)", adf_result$statistic, adf_result$p_value, adf_result$decision)
    ),
    col = c("#009e73", "#15803d", "#475569", "#ea580c", NA),
    lty = c(1, 1, 2, 3, NA),
    pch = c(16, NA, NA, NA, NA),
    lwd = c(1.5, 2.4, 1.8, 1.8, NA),
    bty = "o", box.col = "#cbd5e1", bg = "#ffffff", cex = 0.8
  )
  dev.off()

  png(plot_path$acf_pacf, width = 1000, height = 550)
  par(mfrow = c(1, 2))
  forecast::Acf(stationary_ts, lag.max = 20, main = paste(label, "- ACF"))
  forecast::Pacf(stationary_ts, lag.max = 20, main = paste(label, "- PACF"))
  par(mfrow = c(1, 1))
  dev.off()

  acf_pacf_diagnosis <- diagnose_acf_pacf(stationary_ts)
  candidate_orders <- generate_candidate_orders(acf_pacf_diagnosis, difference_order)
  model_names <- sprintf(
    "ARIMA(%s,%s,%s)",
    candidate_orders$p,
    candidate_orders$d,
    candidate_orders$q
  )
  fits <- lapply(
    seq_len(nrow(candidate_orders)),
    function(i) safe_arima(variance_adjusted_ts, order = as.numeric(candidate_orders[i, ]))
  )
  valid_index <- which(!vapply(fits, is.null, logical(1)))

  if (length(valid_index) == 0) {
    stop("No ARIMA candidate model could be fitted for ", label)
  }

  model_comparison <- data.frame(
    model = model_names[valid_index],
    aic = vapply(fits[valid_index], AIC, numeric(1)),
    log_likelihood = vapply(fits[valid_index], function(fit) as.numeric(logLik(fit)), numeric(1))
  )
  model_comparison <- model_comparison[order(model_comparison$aic), ]
  rownames(model_comparison) <- NULL

  best_model_name <- model_comparison$model[1]
  best_fit <- fits[[valid_index[match(best_model_name, model_names[valid_index])]]]
  selected_coef <- coefficient_table(best_fit)

  diag_result <- diagnostic_tests(best_fit)

  png(plot_path$diagnostics, width = 1000, height = 750)
  checkresiduals(best_fit)
  dev.off()

  forecast_horizon <- if (has_test_data) nrow(test_data) else future_horizon
  forecast_result <- predict(best_fit, n.ahead = forecast_horizon)
  forecast_mean <- as.numeric(forecast_result$pred)
  forecast_se <- as.numeric(forecast_result$se)
  forecast_lower <- forecast_mean - 1.96 * forecast_se
  forecast_upper <- forecast_mean + 1.96 * forecast_se

  if (lambda != 1) {
    forecast_mean_original <- inverse_box_cox(forecast_mean, lambda)
    forecast_lower_original <- inverse_box_cox(forecast_lower, lambda)
    forecast_upper_original <- inverse_box_cox(forecast_upper, lambda)
  } else {
    forecast_mean_original <- forecast_mean
    forecast_lower_original <- forecast_lower
    forecast_upper_original <- forecast_upper
  }

  forecast_period <- if (has_test_data) {
    test_data$period
  } else {
    seq(max(model_data$period) + 1, max(model_data$period) + forecast_horizon)
  }

  forecast_table <- data.frame(
    period = forecast_period,
    forecast = forecast_mean_original,
    lower_95 = forecast_lower_original,
    upper_95 = forecast_upper_original
  )

  accuracy <- NULL
  if (has_test_data) {
    forecast_table$actual <- test_data$value
    forecast_table$error <- forecast_table$actual - forecast_table$forecast
    forecast_table$absolute_error <- abs(forecast_table$error)
    forecast_table$absolute_percentage_error <- abs(forecast_table$error / forecast_table$actual) * 100
    forecast_table <- forecast_table[
      c("period", "actual", "forecast", "lower_95", "upper_95", "error", "absolute_error", "absolute_percentage_error")
    ]
    accuracy <- list(
      mae = mean(forecast_table$absolute_error),
      rmse = sqrt(mean(forecast_table$error^2)),
      mape = mean(forecast_table$absolute_percentage_error)
    )
  }

  write.csv(forecast_table, forecast_path, row.names = FALSE)

  png(plot_path$forecast, width = 900, height = 550)
  plot(
    model_data$period,
    model_data$value,
    type = "o",
    pch = 16,
    col = "#1f77b4",
    xlim = range(c(model_data$period, forecast_period)),
    ylim = range(c(model_data$value, if (has_test_data) test_data$value else numeric(0), forecast_lower_original, forecast_upper_original), na.rm = TRUE),
    xlab = "Period",
    ylab = "Daily average number of defects",
    main = paste(label, "- Forecast Using", best_model_name)
  )
  if (has_test_data) {
    lines(test_data$period, test_data$value, type = "o", pch = 16, col = "#009e73")
  }
  lines(forecast_period, forecast_mean_original, type = "o", pch = 16, col = "#d55e00")
  lines(forecast_period, forecast_lower_original, lty = 2, col = "#d55e00")
  lines(forecast_period, forecast_upper_original, lty = 2, col = "#d55e00")
  abline(v = max(model_data$period), lty = 3)
  legend(
    "topright",
    legend = if (has_test_data) c("Modelling actual", "Remaining actual", "Forecast", "95% interval") else c("Observed", "Forecast", "95% interval"),
    col = if (has_test_data) c("#1f77b4", "#009e73", "#d55e00", "#d55e00") else c("#1f77b4", "#d55e00", "#d55e00"),
    lty = if (has_test_data) c(1, 1, 1, 2) else c(1, 1, 2),
    pch = if (has_test_data) c(16, 16, 16, NA) else c(16, 16, NA),
    bty = "n"
  )
  grid()
  dev.off()

  list(
    label = label,
    prefix = prefix,
    model_data = model_data,
    test_data = test_data,
    has_test_data = has_test_data,
    lambda = lambda,
    variance_result = variance_result,
    variance_treatment = variance_treatment,
    adf_result_before_difference = adf_result_before_difference,
    adf_lag_strategy = adf_lag_strategy,
    mean_acf_pacf_before_difference = mean_acf_pacf_before_difference,
    mean_acf_pacf_final = mean_acf_pacf_final,
    initial_stationarity_alignment = initial_stationarity_alignment,
    final_stationarity_alignment = final_stationarity_alignment,
    mean_initially_stationary = mean_initially_stationary,
    difference_order = difference_order,
    adf_result = adf_result,
    mean_treatment = mean_treatment,
    acf_pacf_diagnosis = acf_pacf_diagnosis,
    candidate_orders = candidate_orders,
    selected_coef = selected_coef,
    model_comparison = model_comparison,
    best_model_name = best_model_name,
    diag_result = diag_result,
    forecast_horizon = forecast_horizon,
    forecast_path = forecast_path,
    forecast_table = forecast_table,
    accuracy = accuracy,
    plot_path = plot_path
  )
}

write_analysis_section <- function(result) {
  cat("## ", result$label, "\n\n", sep = "")

  cat(sprintf("- **Modelling observations:** %s, periods %s-%s\n", nrow(result$model_data), min(result$model_data$period), max(result$model_data$period)))
  if (result$has_test_data) {
    cat(sprintf("- **Remaining forecast test observations:** %s, periods %s-%s\n", nrow(result$test_data), min(result$test_data$period), max(result$test_data$period)))
  } else {
    cat("- **Forecast type:** future forecast after the last observed period; no held-out accuracy metrics.\n")
  }
  cat("\n")

  cat("### 1. Time Series Plot\n\n")
  write_image(result$plot_path$time_series, paste(result$label, "time series plot"))

  cat("### 2. Stationarity Check Following the Box-Jenkins Flow\n\n")
  cat("The diagram below evaluates stationarity before and after differencing using trend and variance line tools alongside ACF and PACF correlograms, aligned with the Box-Jenkins methodology in `docs/ARIMA_Box-Jenkins.pdf`.\n\n")
  write_image(result$plot_path$stationarity_decision, paste(result$label, "stationarity evaluation diagram"))

  cat("#### A. Stationary in Variance?\n\n")
  cat("- **H0:** variance in the first and second half is equal, so data is stationary in variance.\n")
  cat("- **H1:** variance is different, so data is not stationary in variance.\n")
  cat(sprintf("- **Variance first half:** %.4f\n", result$variance_result$variance_first_half))
  cat(sprintf("- **Variance second half:** %.4f\n", result$variance_result$variance_second_half))
  cat(sprintf("- **F statistic:** %.4f\n", result$variance_result$statistic))
  cat(sprintf("- **p-value:** %.4f\n", result$variance_result$p_value))
  cat(sprintf("- **Alpha:** %.2f\n", result$variance_result$alpha))
  cat("- **Decision rule:** reject H0 if p-value < alpha.\n")
  cat("- **Decision:** ", result$variance_result$decision, "\n", sep = "")
  cat("- **Conclusion:** modelling series is ", result$variance_result$conclusion, ".\n", sep = "")
  cat("- **Treatment:** ", result$variance_treatment, "\n\n", sep = "")
  cat("**ACF/PACF note for variance:** ACF and PACF do not directly test stationarity in variance. They are used below for mean-stationarity and model-order diagnosis. Variance stationarity is decided here from the variance comparison and time-series plot.\n\n")
  write_image(result$plot_path$variance, paste(result$label, "variance stationarity check"))

  cat("#### B. Stationary in Mean?\n\n")
  cat("Tested after the variance step using both ACF/PACF behavior and the ADF H0 mechanism.\n\n")
  cat("**ACF/PACF decision before differencing:**\n\n")
  cat(sprintf("- **Significance threshold:** +/- %.4f, calculated as +/- 2/sqrt(n).\n", result$mean_acf_pacf_before_difference$threshold))
  cat(sprintf("- **ACF lag 1:** %.4f\n", result$mean_acf_pacf_before_difference$acf_lag_1))
  cat(sprintf("- **PACF lag 1:** %.4f\n", result$mean_acf_pacf_before_difference$pacf_lag_1))
  cat("- **Significant ACF lags:** ", format_lags(result$mean_acf_pacf_before_difference$significant_acf_lags), "\n", sep = "")
  cat("- **Significant PACF lags:** ", format_lags(result$mean_acf_pacf_before_difference$significant_pacf_lags), "\n", sep = "")
  cat("- **ACF/PACF mean-stationarity decision:** ", result$mean_acf_pacf_before_difference$decision, "\n", sep = "")
  cat("- **Reason:** ", result$mean_acf_pacf_before_difference$reason, "\n\n", sep = "")

  cat("**ADF decision:**\n\n")
  cat("- **ADF test function:** `tseries::adf.test()`\n")
  cat("- **H0:** gamma = 0, series has a unit root, so data is not stationary in mean.\n")
  cat("- **H1:** gamma < 0, series has no unit root, so data is stationary in mean.\n")
  cat(sprintf("- **Initial ADF statistic before differencing:** %.4f\n", result$adf_result_before_difference$statistic))
  cat(sprintf("- **Initial selected lag parameter:** %s\n", result$adf_result_before_difference$selected_lag))
  cat(sprintf("- **Initial ADF p-value:** %.4f\n", result$adf_result_before_difference$p_value))
  cat(sprintf("- **Final ADF statistic:** %.4f\n", result$adf_result$statistic))
  cat(sprintf("- **Final selected lag parameter:** %s\n", result$adf_result$selected_lag))
  cat(sprintf("- **Final ADF p-value:** %.4f\n", result$adf_result$p_value))
  cat(sprintf("- **Alpha:** %.2f\n", result$adf_result$alpha))
  cat("- **Decision rule:** reject H0 if p-value < alpha.\n")
  cat("- **Decision:** ", result$adf_result$decision, "\n", sep = "")
  if (result$adf_result$reject_h0) {
    cat(sprintf("- **Reason:** p-value (%.4f) < alpha (%.2f).\n", result$adf_result$p_value, result$adf_result$alpha))
  } else {
    cat(sprintf("- **Reason:** p-value (%.4f) >= alpha (%.2f).\n", result$adf_result$p_value, result$adf_result$alpha))
  }
  cat("- **Conclusion:** modelling series is ", result$adf_result$conclusion, " at 5% significance level.\n", sep = "")
  cat("- **Treatment:** ", result$mean_treatment, "\n\n", sep = "")
  cat("**Alignment check:**\n\n")
  cat("- **Initial ACF/PACF vs initial ADF:** ", if (result$initial_stationarity_alignment) "aligned." else "not aligned.", "\n", sep = "")
  cat("- **Final ACF/PACF decision after treatment:** ", result$mean_acf_pacf_final$decision, "\n", sep = "")
  cat("- **Final ADF decision after treatment:** ", result$adf_result$conclusion, "\n", sep = "")
  cat("- **Final ACF/PACF vs final ADF:** ", if (result$final_stationarity_alignment) "aligned." else "not aligned.", "\n\n", sep = "")
  write_image(result$plot_path$mean, paste(result$label, "mean stationarity check"))

  cat("#### C. Non-Stationarity Factor Diagnosis\n\n")
  cat("- **Variance factor:** ", if (result$variance_result$reject_h0) "not stationary, handled by Box-Cox check." else "stationary, no Box-Cox needed.", "\n", sep = "")
  mean_factor_text <- if (!result$initial_stationarity_alignment) {
    paste0(
      "conflicting initial evidence: ACF/PACF indicates ",
      result$mean_acf_pacf_before_difference$decision,
      ", while ADF indicates ",
      result$adf_result_before_difference$conclusion,
      "; the computational workflow follows the ADF treatment path."
    )
  } else if (result$mean_initially_stationary) {
    "stationary, no differencing needed."
  } else {
    "initially not stationary, handled by differencing."
  }
  cat("- **Mean factor:** ", mean_factor_text, "\n", sep = "")
  cat("- **Final status:** ", if (result$adf_result$reject_h0) "series is ready for ACF/PACF identification." else "series is still not stationary; review transformation/differencing.", "\n\n", sep = "")

  cat("#### D. Model Identification (ACF and PACF)\n\n")
  write_image(result$plot_path$acf_pacf, paste(result$label, "ACF and PACF"))
  cat(sprintf("- **Significance threshold:** +/- %.4f, calculated as +/- 2/sqrt(n).\n", result$acf_pacf_diagnosis$threshold))
  cat("- **Significant ACF lags:** ", format_lags(result$acf_pacf_diagnosis$significant_acf_lags), "\n", sep = "")
  cat("- **Significant PACF lags:** ", format_lags(result$acf_pacf_diagnosis$significant_pacf_lags), "\n", sep = "")
  cat("- **Rule-based diagnosis:** ", result$acf_pacf_diagnosis$diagnosis, "\n", sep = "")
  cat(sprintf("- **p range from PACF:** 0..%s\n", result$acf_pacf_diagnosis$p_range_max))
  cat(sprintf("- **q range from ACF:** 0..%s\n", result$acf_pacf_diagnosis$q_range_max))
  displayed_candidate <- gsub(",d,", paste0(",", result$difference_order, ","), result$acf_pacf_diagnosis$candidate)
  cat("- **Candidate from ACF/PACF:** ", displayed_candidate, "\n", sep = "")
  cat("- **Candidate estimation rule:** estimate the full p/q grid inside the ACF/PACF-derived range, then select by AIC and validate with residual diagnostics.\n\n")

  cat("### 3. Parameter Estimation and Model Selection\n\n")
  cat(sprintf("Estimated on variance-adjusted series with `d = %s`.\n\n", result$difference_order))
  cat("**Candidate orders estimated:**\n\n")
  write_data_frame_block(result$candidate_orders)
  cat("**Model comparison:**\n\n")
  write_data_frame_block(result$model_comparison)
  cat(sprintf("**Selected model by lowest AIC:** `%s`\n\n", result$best_model_name))
  cat("**Selected model coefficients:**\n\n")
  write_data_frame_block(result$selected_coef)

  cat("### 4. Diagnostic Checking IIDN\n\n")
  write_image(result$plot_path$diagnostics, paste(result$label, "residual diagnostics"))
  cat(sprintf("- **Mean residual:** %.6f\n", result$diag_result$mean_residual))
  cat(sprintf("- **Residual variance:** %.6f\n", result$diag_result$variance_residual))
  cat(sprintf("- **Independence test, Ljung-Box lag %s p-value:** %.4f\n", result$diag_result$lb_lag, result$diag_result$ljung_box$p.value))
  cat(sprintf("- **Normality test, Shapiro-Wilk p-value:** %.4f\n", result$diag_result$shapiro$p.value))
  cat("- **IIDN interpretation:** independent if Ljung-Box p-value > 0.05; normally distributed if Shapiro-Wilk p-value > 0.05; identically distributed is checked visually from residual plot and stable residual spread.\n\n")

  cat("### 5. Forecasting\n\n")
  write_image(result$plot_path$forecast, paste(result$label, "forecast"))
  cat(sprintf("- **Forecast model:** `%s`\n", result$best_model_name))
  cat(sprintf("- **Forecast horizon:** %s periods\n", result$forecast_horizon))
  if (!is.null(result$accuracy)) {
    cat(sprintf("- **MAE:** %.4f\n", result$accuracy$mae))
    cat(sprintf("- **RMSE:** %.4f\n", result$accuracy$rmse))
    cat(sprintf("- **MAPE:** %.2f%%\n", result$accuracy$mape))
  } else {
    cat("- **Accuracy metrics:** not available because all observations are used for modelling.\n")
  }
  cat("- **Forecast CSV:** `", relative_path(result$forecast_path), "`\n\n", sep = "")
  cat("**Forecast values:**\n\n")
  write_data_frame_block(result$forecast_table)
}

write_book_comparison <- function(full_result, split_result, book_acf_pacf) {
  cat("## Comparison with the Original Book Analysis\n\n")
  cat("The original W1 example in the book uses the same 45 daily observations and identifies the series from the time-series plot plus the raw ACF/PACF pattern.\n\n")
  cat("### Book Reference Result\n\n")
  cat("- The book describes W1 as having stationary constant mean and variance.\n")
  cat("- The book's ACF decays gradually.\n")
  cat("- The book's PACF has one main significant spike at lag 1.\n")
  cat("- The book concludes that W1 is likely generated by an AR(1) process, i.e. `ARIMA(1,0,0)`.\n\n")
  cat("Book ACF/PACF values and standard errors shown in the source are stored in `", relative_path(book_acf_pacf_path), "`.\n\n", sep = "")
  cat("The significance flags below use the rule `abs(estimate) > 2 * St.E.`.\n\n")
  write_data_frame_block(book_acf_pacf)

  cat("### Our Independent Analysis Result\n\n")
  cat("- Our independent workflow applies formal variance testing and ADF testing with lag selection by AIC.\n")
  cat("- Our full-data selected model is `", full_result$best_model_name, "`.\n", sep = "")
  cat("- Our 80:20 split selected model is `", split_result$best_model_name, "`.\n", sep = "")
  if (!is.null(split_result$accuracy)) {
    cat(sprintf(
      "- 80:20 split accuracy: MAE = %.4f, RMSE = %.4f, MAPE = %.2f%%.\n",
      split_result$accuracy$mae,
      split_result$accuracy$rmse,
      split_result$accuracy$mape
    ))
  }
  cat("\n")

  cat("### Interpretation\n\n")
  cat("The book's AR(1) conclusion is based on raw W1 ACF/PACF identification. Our independent procedure may select a different model because it first applies an ADF-based stationarity decision and then estimates candidates after any required treatment. This is the comparison point: the book gives the classical identification result, while our workflow documents what happens when the full Box-Jenkins decision path is applied computationally.\n\n")
}

truck_defects <- read.csv(data_path)
book_acf_pacf <- read.csv(book_acf_pacf_path)

if (!all(c("period", "value") %in% names(truck_defects))) {
  stop("Expected CSV columns: period,value")
}

if (!all(c("lag", "book_acf", "book_acf_stderr", "book_pacf", "book_pacf_stderr") %in% names(book_acf_pacf))) {
  stop("Expected book comparison CSV columns: lag,book_acf,book_acf_stderr,book_pacf,book_pacf_stderr")
}

book_acf_pacf$book_acf_significant <- abs(book_acf_pacf$book_acf) > 2 * book_acf_pacf$book_acf_stderr
book_acf_pacf$book_pacf_significant <- abs(book_acf_pacf$book_pacf) > 2 * book_acf_pacf$book_pacf_stderr

truck_defects <- truck_defects[order(truck_defects$period), ]
n_total <- nrow(truck_defects)
n_train <- floor(0.8 * n_total)
n_test <- n_total - n_train

train_data <- truck_defects[seq_len(n_train), ]
test_data <- truck_defects[(n_train + 1):n_total, ]

full_result <- run_box_jenkins_analysis(
  label = "Analysis 1: Full Data Modelling (45 Entries)",
  model_data = truck_defects,
  prefix = "full_data",
  forecast_path = full_forecast_path,
  future_horizon = n_test
)

split_result <- run_box_jenkins_analysis(
  label = "Analysis 2: 80:20 Split Modelling and Forecast Test",
  model_data = train_data,
  test_data = test_data,
  prefix = "split_80_20",
  forecast_path = split_forecast_path,
  future_horizon = n_test
)

sink(report_path)
cat("# Time Series Analysis of Truck Manufacturing Defects W1\n\n")
cat("- **Project root:** `", project_root, "`\n", sep = "")
cat("- **Data source:** `", relative_path(data_path), "`\n", sep = "")
cat("- **Book comparison source:** `", relative_path(book_acf_pacf_path), "`\n", sep = "")
cat("- **Total observations:** ", n_total, "\n", sep = "")
cat(sprintf("- **80:20 split:** %s modelling observations and %s forecast test observations\n\n", n_train, n_test))

cat("## PDF Method Alignment\n\n")
cat("The workflow below follows the ARIMA Box-Jenkins notes in `docs/ARIMA_Box-Jenkins.pdf`:\n\n")
cat("- **Stationary in variance:** check from the time-series plot and variance behavior. The PDF notes that variance non-stationarity is not visible in the correlogram; use Box-Cox if variance is not stable.\n")
cat("- **Stationary in mean:** check the ACF/PACF pattern and the ADF test. ACF that dies down quickly and enters the +/- 2/sqrt(n) band supports stationarity in mean; ACF that starts near 1 and decays slowly suggests non-stationarity in mean.\n")
cat("- **ADF decision:** H0 means unit root / not stationary. Reject H0 when the ADF statistic is below the critical value or p-value < alpha. If H0 is not rejected, apply differencing and test again.\n")
cat("- **Model identification:** after the stationarity treatment, use ACF/PACF to form candidate ARIMA orders, then estimate parameters and compare candidate models.\n\n")

write_analysis_section(full_result)
write_analysis_section(split_result)
write_book_comparison(full_result, split_result, book_acf_pacf)
sink()

message("Analysis complete.")
message("Project root: ", project_root)
message("Full data selected model: ", full_result$best_model_name)
message("80:20 split selected model: ", split_result$best_model_name)
if (!is.null(split_result$accuracy)) {
  message(sprintf(
    "80:20 split forecast accuracy: MAE = %.4f, RMSE = %.4f, MAPE = %.2f%%",
    split_result$accuracy$mae,
    split_result$accuracy$rmse,
    split_result$accuracy$mape
  ))
}
message("Saved Markdown report to ", report_path)
