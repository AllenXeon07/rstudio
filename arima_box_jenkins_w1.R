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
  if (length(fit$coef) == 0) {
    return(data.frame(note = "No AR, MA, or intercept coefficients estimated."))
  }

  se <- sqrt(diag(fit$var.coef))
  z_value <- fit$coef / se
  p_value <- 2 * (1 - pnorm(abs(z_value)))

  data.frame(
    parameter = names(fit$coef),
    estimate = as.numeric(fit$coef),
    std_error = as.numeric(se),
    z_value = as.numeric(z_value),
    p_value = as.numeric(p_value),
    row.names = NULL
  )
}

diagnostic_tests <- function(fit) {
  resid <- residuals(fit)
  fitdf <- length(fit$coef)
  lb_lag <- min(10, length(resid) - fitdf - 1)

  list(
    residuals = resid,
    ljung_box = Box.test(resid, lag = lb_lag, type = "Ljung-Box", fitdf = fitdf),
    shapiro = shapiro.test(resid),
    lb_lag = lb_lag,
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
  lambdas <- seq(-2, 2, by = 0.05)
  log_likelihood <- vapply(lambdas, function(lambda) {
    transformed <- box_cox_transform(x, lambda)
    -length(x) / 2 * log(var(transformed)) + (lambda - 1) * sum(log(x))
  }, numeric(1))

  lambdas[which.max(log_likelihood)]
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

adf_stationarity_check <- function(x, alpha = 0.05, critical_value = -2.86, max_lag = NULL) {
  values <- as.numeric(x)
  values_diff <- diff(values)

  if (is.null(max_lag)) {
    max_lag <- min(5, floor((length(values) - 1) / 4))
  }

  adf_candidates <- list()
  for (lag_order in 0:max_lag) {
    diff_index <- (lag_order + 1):length(values_diff)
    adf_data <- data.frame(
      response = values_diff[diff_index],
      lagged_level = values[diff_index]
    )

    if (lag_order > 0) {
      for (lag_i in 1:lag_order) {
        adf_data[[paste0("diff_lag_", lag_i)]] <- values_diff[diff_index - lag_i]
      }
    }

    model <- lm(response ~ ., data = adf_data)
    adf_candidates[[lag_order + 1]] <- list(
      lag_order = lag_order,
      model = model,
      aic = AIC(model)
    )
  }

  aic_values <- vapply(adf_candidates, function(candidate) candidate$aic, numeric(1))
  best_candidate <- adf_candidates[[which.min(aic_values)]]
  model <- best_candidate$model
  statistic <- summary(model)$coefficients["lagged_level", "t value"]
  reject_h0 <- statistic < critical_value

  list(
    alpha = alpha,
    statistic = statistic,
    critical_value = critical_value,
    selected_lag = best_candidate$lag_order,
    selected_aic = best_candidate$aic,
    reject_h0 = reject_h0,
    decision = if (reject_h0) "Reject H0" else "Fail to reject H0",
    conclusion = if (reject_h0) "stationary in mean" else "not stationary in mean",
    regression_type = "With constant",
    fit = model
  )
}

safe_arima <- function(x, order) {
  tryCatch(
    arima(x, order = order, method = "ML"),
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

draw_wrapped_box <- function(x, y, width, height, label, fill, border = "#1f2a44", text_col = "#16213a", cex = 0.9) {
  rect(x - width / 2, y - height / 2, x + width / 2, y + height / 2, col = fill, border = border, lwd = 2)
  lines <- strwrap(label, width = 28)
  text(x, y, paste(lines, collapse = "\n"), cex = cex, col = text_col, font = 2)
}

draw_flow_arrow <- function(x0, y0, x1, y1, label = NULL) {
  arrows(x0, y0, x1, y1, length = 0.08, lwd = 2, col = "#334155")
  if (!is.null(label)) {
    text((x0 + x1) / 2, (y0 + y1) / 2 + 0.025, label, cex = 0.8, col = "#334155", font = 2)
  }
}

draw_stationarity_decision_diagram <- function(
  path,
  label,
  variance_result,
  variance_treatment,
  mean_acf_pacf_before_difference,
  adf_result_before_difference,
  adf_result,
  mean_treatment,
  difference_order
) {
  variance_fill <- if (variance_result$reject_h0) "#fde2d2" else "#dff1e6"
  mean_initial_fill <- if (adf_result_before_difference$reject_h0) "#dff1e6" else "#fde2d2"
  mean_final_fill <- if (adf_result$reject_h0) "#dff1e6" else "#fde2d2"

  png(path, width = 1200, height = 720)
  par(mar = c(0, 0, 0, 0), xpd = NA)
  plot.new()
  plot.window(xlim = c(0, 1), ylim = c(0, 1))

  text(0.03, 0.95, paste(label, "- Stationarity Decision Diagram"), adj = 0, cex = 1.35, font = 2, col = "#16213a")
  text(0.03, 0.90, "Box-Jenkins stationarity path: check variance first, then check mean.", adj = 0, cex = 0.9, col = "#475569")

  text(0.03, 0.81, "Variance Stationarity", adj = 0, cex = 1.05, font = 2, col = "#1f5f99")
  draw_wrapped_box(0.14, 0.68, 0.19, 0.16, "Plot modelling data and compare variance in first vs second half", "#e8f1fb")
  draw_wrapped_box(
    0.39,
    0.68,
    0.20,
    0.18,
    sprintf(
      "F-test H0: equal variance\np = %.4f, alpha = %.2f\nDecision: %s",
      variance_result$p_value,
      variance_result$alpha,
      variance_result$decision
    ),
    variance_fill
  )
  draw_wrapped_box(
    0.65,
    0.68,
    0.20,
    0.16,
    paste("Conclusion:", variance_result$conclusion),
    variance_fill
  )
  draw_wrapped_box(0.88, 0.68, 0.18, 0.16, variance_treatment, "#fff1dc")
  draw_flow_arrow(0.235, 0.68, 0.29, 0.68)
  draw_flow_arrow(0.49, 0.68, 0.55, 0.68)
  draw_flow_arrow(0.75, 0.68, 0.79, 0.68)

  text(0.03, 0.49, "Mean Stationarity", adj = 0, cex = 1.05, font = 2, col = "#1f5f99")
  draw_wrapped_box(
    0.14,
    0.34,
    0.19,
    0.20,
    sprintf(
      "ACF/PACF check\nACF lag 1 = %.4f\nPACF lag 1 = %.4f\nDecision: %s",
      mean_acf_pacf_before_difference$acf_lag_1,
      mean_acf_pacf_before_difference$pacf_lag_1,
      mean_acf_pacf_before_difference$decision
    ),
    "#e8f1fb",
    cex = 0.82
  )
  draw_wrapped_box(
    0.39,
    0.34,
    0.20,
    0.20,
    sprintf(
      "ADF H0: unit root\nstat = %.4f\ncritical = %.2f\nDecision: %s",
      adf_result_before_difference$statistic,
      adf_result_before_difference$critical_value,
      adf_result_before_difference$decision
    ),
    mean_initial_fill,
    cex = 0.82
  )
  draw_wrapped_box(
    0.65,
    0.34,
    0.20,
    0.18,
    sprintf("Treatment\n%s", mean_treatment),
    "#fff1dc"
  )
  draw_wrapped_box(
    0.88,
    0.34,
    0.18,
    0.20,
    sprintf(
      "Final ADF\nstat = %.4f\ncritical = %.2f\nd = %s\nConclusion: %s",
      adf_result$statistic,
      adf_result$critical_value,
      difference_order,
      adf_result$conclusion
    ),
    mean_final_fill,
    cex = 0.8
  )
  draw_flow_arrow(0.235, 0.34, 0.29, 0.34)
  draw_flow_arrow(0.49, 0.34, 0.55, 0.34)
  draw_flow_arrow(0.75, 0.34, 0.79, 0.34)

  text(
    0.03,
    0.09,
    "Interpretation: green boxes indicate stationarity/fail-safe status; orange boxes indicate treatment; the final stationary series is used for ACF/PACF model identification.",
    adj = 0,
    cex = 0.85,
    col = "#475569"
  )
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

  adf_lag_strategy <- "Independent analysis: choose the number of lagged differenced terms automatically by AIC, then apply the ADF H0 decision rule."
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
    variance_result = variance_result,
    variance_treatment = variance_treatment,
    mean_acf_pacf_before_difference = mean_acf_pacf_before_difference,
    adf_result_before_difference = adf_result_before_difference,
    adf_result = adf_result,
    mean_treatment = mean_treatment,
    difference_order = difference_order
  )

  png(plot_path$variance, width = 900, height = 550)
  plot(
    variance_adjusted_ts,
    type = "o",
    pch = 16,
    col = "#d55e00",
    xlab = "Period",
    ylab = "Value",
    main = paste(label, "- Variance Stationarity / Box-Cox Result")
  )
  grid()
  dev.off()

  png(plot_path$mean, width = 900, height = 550)
  plot(
    stationary_ts,
    type = "o",
    pch = 16,
    col = "#009e73",
    xlab = "Period",
    ylab = "Stationary series value",
    main = sprintf("%s - Mean Stationarity / Differencing Result (d = %s)", label, difference_order)
  )
  grid()
  dev.off()

  png(plot_path$acf_pacf, width = 1000, height = 550)
  par(mfrow = c(1, 2))
  acf(stationary_ts, lag.max = 20, main = paste(label, "- ACF"))
  pacf(stationary_ts, lag.max = 20, main = paste(label, "- PACF"))
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

  png(plot_path$diagnostics, width = 1000, height = 800)
  par(mfrow = c(2, 2))
  plot(diag_result$residuals, type = "o", pch = 16, main = "Residual Plot", ylab = "Residual")
  abline(h = 0, col = "red")
  acf(diag_result$residuals, lag.max = 20, main = "ACF of Residuals")
  hist(diag_result$residuals, breaks = 10, main = "Histogram of Residuals", xlab = "Residual")
  qqnorm(diag_result$residuals, main = "Normal Q-Q Plot")
  qqline(diag_result$residuals, col = "red")
  par(mfrow = c(1, 1))
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
  cat("The diagram below summarizes the variance and mean stationarity decisions before the detailed statistical output.\n\n")
  write_image(result$plot_path$stationarity_decision, paste(result$label, "stationarity decision diagram"))

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
  cat("- **ADF lag strategy:** ", result$adf_lag_strategy, "\n", sep = "")
  cat("- **H0:** gamma = 0, data has a unit root, so data is not stationary in mean.\n")
  cat("- **H1:** gamma < 0, data has no unit root, so data is stationary in mean.\n")
  cat(sprintf("- **Initial ADF statistic before differencing:** %.4f\n", result$adf_result_before_difference$statistic))
  cat(sprintf("- **Initial selected lag by AIC:** %s\n", result$adf_result_before_difference$selected_lag))
  cat(sprintf("- **Final ADF statistic:** %.4f\n", result$adf_result$statistic))
  cat(sprintf("- **Final selected lag by AIC:** %s\n", result$adf_result$selected_lag))
  cat(sprintf("- **Final ADF regression AIC:** %.4f\n", result$adf_result$selected_aic))
  cat(sprintf("- **Alpha:** %.2f\n", result$adf_result$alpha))
  cat(sprintf("- **Critical value at 5%%:** %.2f\n", result$adf_result$critical_value))
  cat("- **Decision rule:** reject H0 if ADF statistic < critical value.\n")
  cat("- **Decision:** ", result$adf_result$decision, "\n", sep = "")
  if (result$adf_result$reject_h0) {
    cat("- **Reason:** ADF statistic is smaller/more negative than the critical value.\n")
  } else {
    cat("- **Reason:** ADF statistic is not smaller/more negative than the critical value.\n")
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
