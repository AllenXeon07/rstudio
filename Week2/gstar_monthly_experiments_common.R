# Shared monthly GSTAR experiment workflow. Loaded by the package and custom entry scripts.
suppressPackageStartupMessages({ library(forecast); library(tseries); library(gstar) })

monthly_gstar_root <- function() {
  args <- commandArgs(trailingOnly = FALSE); script <- sub("--file=", "", args[grepl("--file=", args)])
  if (length(script) && nchar(script)) normalizePath(dirname(script), mustWork = FALSE) else if (dir.exists("/home/rstudio/project/Week2")) "/home/rstudio/project/Week2" else getwd()
}
safe_eval <- function(expr) tryCatch(expr, error = function(e) e)
md_table <- function(tab, digits = 6L) {
  tab <- as.data.frame(tab, check.names = FALSE)
  tab[] <- lapply(tab, function(x) if (is.numeric(x)) format(round(x, digits), trim = TRUE, scientific = FALSE) else as.character(x))
  c(paste0("| ", paste(names(tab), collapse = " | "), " |"), paste0("|", paste(rep("---", ncol(tab)), collapse = "|"), "|"), apply(tab, 1, function(row) paste0("| ", paste(row, collapse = " | "), " |")))
}
metric_table <- function(actual, predicted, locations) {
  one <- function(a, p, label) {
    nonzero <- a != 0; sst <- sum((a - mean(a))^2); r2 <- if (sst > .Machine$double.eps) 1 - sum((a - p)^2) / sst else NA_real_
    data.frame(location = label, MSE = mean((a - p)^2), RMSE = sqrt(mean((a - p)^2)), MAE = mean(abs(a - p)), sMAPE = mean(200 * abs(a - p) / (abs(a) + abs(p) + .Machine$double.eps)), MAPE_nonzero = if (any(nonzero)) mean(abs((a[nonzero] - p[nonzero]) / a[nonzero])) * 100 else NA_real_, R_squared = r2)
  }
  rbind(do.call(rbind, lapply(seq_along(locations), function(j) one(actual[, j], predicted[, j], locations[j]))), one(as.vector(actual), as.vector(predicted), "Overall"))
}
stationarity_results <- function(values, locations, stage, max_adf_lag) {
  variance <- do.call(rbind, lapply(seq_along(locations), function(j) {
    groups <- factor(rep(c("first_half", "second_half"), c(floor(nrow(values) / 2), ceiling(nrow(values) / 2))))
    z <- safe_eval(fligner.test(values[, j] ~ groups)); data.frame(stage = stage, location = locations[j], test = "Fligner-Killeen variance", lag = NA_integer_, statistic = if (inherits(z, "error")) NA_real_ else unname(z$statistic), p_value = if (inherits(z, "error")) NA_real_ else z$p.value, stationary = if (inherits(z, "error")) NA else z$p.value >= .05)
  }))
  mean <- do.call(rbind, lapply(seq_along(locations), function(j) {
    adf <- do.call(rbind, lapply(0:max_adf_lag, function(k) { z <- safe_eval(adf.test(values[, j], alternative = "stationary", k = k)); data.frame(stage = stage, location = locations[j], test = "ADF", lag = k, statistic = if (inherits(z, "error")) NA_real_ else unname(z$statistic), p_value = if (inherits(z, "error")) NA_real_ else z$p.value, stationary = if (inherits(z, "error")) NA else z$p.value < .05) }))
    z <- safe_eval(kpss.test(values[, j], null = "Level")); rbind(adf, data.frame(stage = stage, location = locations[j], test = "KPSS", lag = NA_integer_, statistic = if (inherits(z, "error")) NA_real_ else unname(z$statistic), p_value = if (inherits(z, "error")) NA_real_ else z$p.value, stationary = if (inherits(z, "error")) NA else z$p.value >= .05))
  }))
  list(variance = variance, mean = mean)
}
is_mean_stationary <- function(tab, locations) vapply(locations, function(location) {
  adf <- tab[tab$location == location & tab$test == "ADF", "stationary"]; kpss <- tab[tab$location == location & tab$test == "KPSS", "stationary"]
  mean(adf, na.rm = TRUE) >= .5 && length(kpss) == 1L && isTRUE(kpss)
}, logical(1))
peak_indices <- function(values, significant) {
  lags <- seq_along(values); magnitudes <- abs(values)
  left <- c(-Inf, magnitudes[-length(magnitudes)]); right <- c(magnitudes[-1L], -Inf)
  which(significant & (magnitudes >= left) & (magnitudes >= right))
}
peak_lags <- function(values, significant, max_peaks = 6L, include_lag_one = TRUE) {
  lags <- seq_along(values); candidates <- peak_indices(values, significant)
  result <- lags[candidates][order(abs(values[candidates]), decreasing = TRUE)]
  if (include_lag_one && length(values) && isTRUE(significant[1])) result <- unique(c(1L, result))
  result <- head(result, max_peaks)
  if (!length(result)) 1L else sort(unique(result))
}
top_peak_lags <- function(rows, max_peaks = 6L) {
  if (!nrow(rows)) return(1L)
  rows <- rows[order(-abs(rows$strength), rows$lag), , drop = FALSE]
  rows <- rows[!duplicated(rows$lag), , drop = FALSE]
  head(sort(unique(rows$lag)), max_peaks)
}
own_city_peak_lags <- function(ap, locations, max_peaks = 6L) {
  rows <- do.call(rbind, lapply(locations, function(loc) {
    z <- ap[ap$location == loc, , drop = FALSE]; idx <- unique(c(peak_indices(z$acf, z$acf_significant), peak_indices(z$pacf, z$pacf_significant), if (isTRUE(z$acf_significant[1]) || isTRUE(z$pacf_significant[1])) 1L else integer()))
    if (!length(idx)) return(data.frame(lag = integer(), strength = numeric(), source = character()))
    data.frame(lag = z$lag[idx], strength = pmax(abs(z$acf[idx]), abs(z$pacf[idx])), source = loc)
  }))
  top_peak_lags(rows, max_peaks)
}
ccf_peak_lags <- function(pair_table, max_peaks = 6L) {
  # CCF signs retain the lead/lag interpretation in the report.  For order
  # identification, l and -l represent the same temporal distance, so retain
  # the strongest significant correlation at each absolute lag.
  pair_table$lag <- as.integer(as.character(pair_table$lag))
  pair_table$ccf <- as.numeric(as.character(pair_table$ccf))
  nonzero <- pair_table[pair_table$lag != 0L, , drop = FALSE]
  collapsed <- do.call(rbind, lapply(split(nonzero, abs(nonzero$lag)), function(z) z[which.max(abs(z$ccf)), , drop = FALSE]))
  collapsed$lag <- as.integer(as.character(collapsed$lag))
  collapsed$ccf <- as.numeric(as.character(collapsed$ccf))
  collapsed <- collapsed[order(abs(collapsed$lag)), , drop = FALSE]
  idx <- unique(c(peak_indices(collapsed$ccf, as.logical(collapsed$significant)), if (isTRUE(collapsed$significant[1])) 1L else integer()))
  if (!length(idx)) return(data.frame(lag = integer(), strength = numeric(), pair = character()))
  data.frame(lag = abs(collapsed$lag[idx]), strength = collapsed$ccf[idx], pair = paste(collapsed$location_x[idx], collapsed$location_y[idx], sep = " / "))
}
acf_pacf_data <- function(values, locations, max_lag) do.call(rbind, lapply(seq_along(locations), function(j) {
  ac <- as.numeric(acf(values[, j], plot = FALSE, lag.max = max_lag)$acf[-1L]); pc <- as.numeric(pacf(values[, j], plot = FALSE, lag.max = max_lag)$acf); bound <- qnorm(.975) / sqrt(nrow(values))
  data.frame(location = locations[j], lag = seq_len(max_lag), acf = ac, pacf = pc, significance_bound = bound, acf_significant = abs(ac) > bound, pacf_significant = abs(pc) > bound)
}))
ccf_data <- function(values, locations, max_lag) {
  pairs <- combn(seq_along(locations), 2L, simplify = FALSE)
  do.call(rbind, lapply(pairs, function(pair) {
    z <- ccf(values[, pair[1]], values[, pair[2]], lag.max = max_lag, plot = FALSE); bound <- qnorm(.975) / sqrt(nrow(values))
    data.frame(location_x = locations[pair[1]], location_y = locations[pair[2]], lag = as.integer(z$lag), ccf = as.numeric(z$acf), significance_bound = bound, significant = abs(as.numeric(z$acf)) > bound, direction = ifelse(z$lag < 0, paste0(locations[pair[2]], " leads ", locations[pair[1]]), ifelse(z$lag > 0, paste0(locations[pair[1]], " leads ", locations[pair[2]]), "contemporaneous")))
  }))
}
diagnose_residuals <- function(residual_matrix, locations) do.call(rbind, lapply(seq_along(locations), function(j) {
  r <- residual_matrix[, j]; groups <- factor(rep(c("first_half", "second_half"), c(floor(length(r) / 2), ceiling(length(r) / 2)))); mt <- safe_eval(t.test(r, mu = 0)); sh <- safe_eval(shapiro.test(r)); fl <- safe_eval(fligner.test(r ~ groups)); lb10 <- safe_eval(Box.test(r, lag = min(10, length(r) - 1L), type = "Ljung-Box")); lb20 <- safe_eval(Box.test(r, lag = min(20, length(r) - 1L), type = "Ljung-Box"))
  data.frame(location = locations[j], mean_residual = mean(r), residual_variance = var(r), mean_zero_p_value = if (inherits(mt, "error")) NA_real_ else mt$p.value, normality_shapiro_p_value = if (inherits(sh, "error")) NA_real_ else sh$p.value, variance_stability_fligner_p_value = if (inherits(fl, "error")) NA_real_ else fl$p.value, ljung_box_10_p_value = if (inherits(lb10, "error")) NA_real_ else lb10$p.value, ljung_box_20_p_value = if (inherits(lb20, "error")) NA_real_ else lb20$p.value)
}))
diagnostic_flags <- function(d) list(iidn = all(d$mean_zero_p_value >= .05 & d$normality_shapiro_p_value >= .05 & d$variance_stability_fligner_p_value >= .05 & d$ljung_box_10_p_value >= .05 & d$ljung_box_20_p_value >= .05), white = all(d$mean_zero_p_value >= .05 & d$variance_stability_fligner_p_value >= .05 & d$ljung_box_10_p_value >= .05 & d$ljung_box_20_p_value >= .05))
gstar_package_equation_terms <- function(fit) {
  parameter <- rownames(fit$B); estimate <- as.numeric(fit$B)
  parsed <- regexec("^psi([0-9]+)([01])\\((.*)\\)$", parameter); pieces <- regmatches(parameter, parsed)
  lag <- vapply(pieces, function(x) if (length(x) == 4L) as.integer(x[2]) else NA_integer_, integer(1))
  code <- vapply(pieces, function(x) if (length(x) == 4L) x[3] else NA_character_, character(1))
  location <- vapply(pieces, function(x) if (length(x) == 4L) x[4] else NA_character_, character(1))
  effect <- ifelse(code == "0", "own-city", "spatially weighted other-city")
  equation_term <- ifelse(code == "0", paste0(round(estimate, 6), " * Z_", location, ",t-", lag), paste0(round(estimate, 6), " * sum_j(W_{j,", location, "} Z_j,t-", lag, ")"))
  data.frame(location = location, lag = lag, effect = effect, parameter = parameter, coefficient = estimate, equation_term = equation_term)
}
one_step_actual_lag_forecast <- function(fit, engine, model_train, test_model, weights) {
  locations <- colnames(model_train); history <- rbind(model_train, test_model); n_ahead <- nrow(test_model); out <- matrix(NA_real_, n_ahead, ncol(model_train), dimnames = list(seq_len(n_ahead), locations))
  if (engine == "package") {
    pad_zero <- getFromNamespace("pad_zero", "gstar"); p <- fit$p
    for (step in seq_len(n_ahead)) {
      time <- nrow(model_train) + step; recent <- history[(time - p):(time - 1L), , drop = FALSE]
      own <- pad_zero(rbind(recent, rep(0, ncol(recent))), p); spatial <- pad_zero(rbind(recent, rep(0, ncol(recent))) %*% weights, p)
      # The package's fitted equation has one pooled response, so its one-step
      # prediction is recycled across locations, matching predict.gstar().
      out[step, ] <- as.numeric(cbind(own, spatial) %*% fit$B)
    }
  } else {
    own_count <- fit$b * length(locations)
    for (step in seq_len(n_ahead)) {
      time <- nrow(model_train) + step
      for (i in seq_along(locations)) {
        own <- sum(vapply(seq_len(fit$b), function(lag) fit$coefficients[(lag - 1L) * length(locations) + i] * history[time - lag, i], numeric(1)))
        spatial <- sum(vapply(seq_len(fit$a), function(lag) fit$coefficients[own_count + (lag - 1L) * length(locations) + i] * sum(weights[i, ] * history[time - lag, ]), numeric(1)))
        out[step, i] <- own + spatial
      }
    }
  }
  out
}

run_monthly_gstar_experiments <- function(engine = c("package", "custom")) {
  engine <- match.arg(engine); root <- monthly_gstar_root()
  if (engine == "custom") source(file.path(root, "gstar_ab.R"))
  tag <- if (engine == "package") "package" else "custom_ab"; result_dir <- file.path(root, "results_monthly_experiments", tag); plot_dir <- file.path(root, "plots_monthly_experiments", tag); dir.create(result_dir, recursive = TRUE, showWarnings = FALSE); dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
  report_path <- file.path(root, if (engine == "package") "gstar_monthly_experiments_report.md" else "gstar_ab_monthly_experiments_report.md")
  rainfall <- read.csv(file.path(root, "data", "rain_fall.csv"), check.names = FALSE); coordinates <- read.csv(file.path(root, "data", "station_coordinates.csv"), stringsAsFactors = FALSE); locations <- names(rainfall); x <- as.matrix(rainfall); storage.mode(x) <- "double"; colnames(x) <- locations
  if (!identical(coordinates$location, locations) || anyNA(x)) stop("Rainfall and coordinate inputs must be complete and aligned.")
  haversine <- function(lat1, lon1, lat2, lon2) { r <- pi / 180; a <- sin((lat2 - lat1) * r / 2)^2 + cos(lat1 * r) * cos(lat2 * r) * sin((lon2 - lon1) * r / 2)^2; 12742 * atan2(sqrt(a), sqrt(1 - a)) }
  distance <- outer(seq_along(locations), seq_along(locations), Vectorize(function(i, j) haversine(coordinates$latitude[i], coordinates$longitude[i], coordinates$latitude[j], coordinates$longitude[j]))); diag(distance) <- 0; dimnames(distance) <- list(locations, locations)
  weights <- matrix(0, ncol(x), ncol(x), dimnames = list(locations, locations)); for (i in seq_len(nrow(weights))) { z <- ifelse(seq_len(ncol(weights)) == i, 0, 1 / distance[i, ]); weights[i, ] <- z / sum(z) }
  write.csv(coordinates, file.path(result_dir, "station_coordinates_used.csv"), row.names = FALSE); write.csv(distance, file.path(result_dir, "station_distance_km.csv"), row.names = TRUE); write.csv(weights, file.path(result_dir, "inverse_distance_weights.csv"), row.names = TRUE)
  splits <- c(`70_30` = .7, `80_20` = .8, `90_10` = .9); summaries <- list(); sections <- list()
  for (split_name in names(splits)) {
    n_train <- floor(nrow(x) * splits[[split_name]]); train_raw <- x[seq_len(n_train), , drop = FALSE]; test_raw <- x[(n_train + 1L):nrow(x), , drop = FALSE]; max_lag <- min(36L, floor(n_train / 3L)); max_adf_lag <- min(36L, floor((n_train - 2L) / 3L))
    raw <- stationarity_results(train_raw, locations, "raw_training", max_adf_lag); apply_boxcox <- any(!raw$variance$stationary, na.rm = TRUE); lambda <- NA_real_; shift <- 0; train_scale <- train_raw
    if (apply_boxcox) { shift <- min(train_raw[train_raw > 0]) / 2; lambda <- BoxCox.lambda(as.numeric(train_raw + shift), method = "loglik"); train_scale <- BoxCox(train_raw + shift, lambda); colnames(train_scale) <- locations }
    transformed <- stationarity_results(train_scale, locations, if (apply_boxcox) "boxcox_training" else "raw_training_reused", max_adf_lag); d <- if (all(is_mean_stationary(transformed$mean, locations))) 0L else 1L; model_train <- if (d == 1L) diff(train_scale) else train_scale; colnames(model_train) <- locations
    differenced <- if (d == 1L) stationarity_results(model_train, locations, "first_difference_training", max_adf_lag) else NULL; variance_all <- rbind(raw$variance, transformed$variance, if (!is.null(differenced)) differenced$variance else NULL); mean_all <- rbind(raw$mean, transformed$mean, if (!is.null(differenced)) differenced$mean else NULL)
    ap <- acf_pacf_data(model_train, locations, max_lag); own_lags <- own_city_peak_lags(ap, locations)
    cc <- ccf_data(model_train, locations, max_lag); spatial_peak_rows <- do.call(rbind, lapply(split(cc, interaction(cc$location_x, cc$location_y, drop = TRUE)), ccf_peak_lags)); spatial_lags <- top_peak_lags(spatial_peak_rows)
    for (j in seq_along(locations)) { png(file.path(plot_dir, paste0(split_name, "_acf_pacf_", tolower(locations[j]), ".png")), 1600, 900, res = 160); par(mfrow = c(1, 2)); acf(model_train[, j], lag.max = max_lag, main = paste("ACF -", locations[j], "(", split_name, ")")); pacf(model_train[, j], lag.max = max_lag, main = paste("PACF -", locations[j], "(", split_name, ")")); dev.off() }
    ccf_pairs <- unique(paste(cc$location_x, cc$location_y, sep = "_")); for (pair in ccf_pairs) { t <- cc[paste(cc$location_x, cc$location_y, sep = "_") == pair, ]; png(file.path(plot_dir, paste0(split_name, "_ccf_", tolower(pair), ".png")), 1600, 900, res = 160); plot(t$lag, t$ccf, type = "h", xlab = "Lag (months)", ylab = "CCF", main = paste("CCF -", gsub("_", " vs ", pair), "(", split_name, ")")); abline(h = c(-t$significance_bound[1], t$significance_bound[1]), col = "blue", lty = 2); abline(h = 0); dev.off() }
    candidate_grid <- if (engine == "package") data.frame(a = sort(unique(c(own_lags, spatial_lags))), b = sort(unique(c(own_lags, spatial_lags)))) else expand.grid(a = spatial_lags, b = own_lags, KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
    if (engine == "package") candidate_grid <- candidate_grid[candidate_grid$a == candidate_grid$b, , drop = FALSE]
    fits <- list(); candidates <- list(); params <- list(); diags <- list(); corrs <- list()
    for (row in seq_len(nrow(candidate_grid))) {
      a <- candidate_grid$a[row]; b <- candidate_grid$b[row]; key <- paste(a, b, sep = "_")
      fit <- if (engine == "package") safe_eval(gstar::gstar(model_train, weight = weights, p = a, d = 0, est = "OLS")) else safe_eval(gstar_ab_fit(model_train, weights, a, b)); fits[[key]] <- fit
      if (inherits(fit, "error")) { candidates[[row]] <- data.frame(a = a, b = b, fitted = FALSE, AIC = NA_real_, coefficients_finite = FALSE, iidn_pass = FALSE, white_noise_pass = FALSE, error = conditionMessage(fit)); next }
      fitted <- if (engine == "package") as.matrix(fit$fitted_values) else fitted(fit); observed <- model_train[(nrow(model_train) - nrow(fitted) + 1L):nrow(model_train), , drop = FALSE]; residual <- observed - fitted; dg <- diagnose_residuals(residual, locations); flags <- diagnostic_flags(dg)
      coef <- if (engine == "package") fit$B else fit$coefficients; se <- if (engine == "package") fit$std_err else fit$std_error; tv <- if (engine == "package") fit$t_value else fit$t_value; pv <- if (engine == "package") fit$p_value else fit$p_value; names(coef) <- if (engine == "package") rownames(fit$B) else names(coef)
      candidates[[row]] <- data.frame(a = a, b = b, fitted = TRUE, AIC = if (engine == "package") fit$AIC else fit$AIC, coefficients_finite = all(is.finite(coef)), iidn_pass = flags$iidn, white_noise_pass = flags$white, error = "")
      params[[key]] <- data.frame(a = a, b = b, parameter = names(coef), estimate = as.numeric(coef), std_error = as.numeric(se), t_value = as.numeric(tv), p_value = as.numeric(pv)); diags[[key]] <- cbind(a = a, b = b, dg); grid <- expand.grid(location_1 = locations, location_2 = locations, stringsAsFactors = FALSE); corrs[[key]] <- data.frame(a = a, b = b, grid, correlation = as.vector(cor(residual)))
    }
    candidates <- do.call(rbind, candidates); params <- do.call(rbind, params); diags <- do.call(rbind, diags); corrs <- do.call(rbind, corrs); valid <- candidates$fitted & candidates$coefficients_finite
    if (!any(valid)) stop("No candidate model could be fitted for split ", split_name, ".")
    full <- valid & candidates$iidn_pass; white <- valid & candidates$white_noise_pass; selection_status <- if (any(full)) "full IIDN" else if (any(white)) "white-noise fallback" else "minimum-AIC eligible fallback"; selected <- if (any(full)) which.min(ifelse(full, candidates$AIC, Inf)) else if (any(white)) which.min(ifelse(white, candidates$AIC, Inf)) else which.min(ifelse(valid, candidates$AIC, Inf)); a <- candidates$a[selected]; b <- candidates$b[selected]; fit <- fits[[paste(a, b, sep = "_")]]; fallback <- selection_status != "full IIDN"
    fitted_model <- if (engine == "package") as.matrix(fit$fitted_values) else fitted(fit); observed_model <- model_train[(nrow(model_train) - nrow(fitted_model) + 1L):nrow(model_train), , drop = FALSE]
    if (d == 0L) { train_pred_scale <- fitted_model; train_actual <- train_scale[(nrow(train_scale) - nrow(fitted_model) + 1L):nrow(train_scale), , drop = FALSE] } else { indices <- (max(a, b) + 2L):nrow(train_scale); train_pred_scale <- train_scale[indices - 1L, , drop = FALSE] + fitted_model; train_actual <- train_scale[indices, , drop = FALSE] }
    test_scale <- if (apply_boxcox) { z <- BoxCox(test_raw + shift, lambda); colnames(z) <- locations; z } else test_raw
    test_model_actual <- if (d == 1L) diff(rbind(train_scale[nrow(train_scale), , drop = FALSE], test_scale)) else test_scale; colnames(test_model_actual) <- locations
    test_pred_model <- if (engine == "package") as.matrix(predict(fit, n = nrow(test_raw))) else predict(fit, n.ahead = nrow(test_raw)); if (d == 1L) test_pred_model <- sweep(apply(test_pred_model, 2, cumsum), 2, train_scale[nrow(train_scale), ], "+"); test_pred_model <- as.matrix(test_pred_model); colnames(test_pred_model) <- locations
    test_pred_actual_lags_model <- one_step_actual_lag_forecast(fit, engine, model_train, test_model_actual, weights); if (d == 1L) test_pred_actual_lags_model <- test_pred_actual_lags_model + rbind(train_scale[nrow(train_scale), , drop = FALSE], test_scale[-nrow(test_scale), , drop = FALSE]); colnames(test_pred_actual_lags_model) <- locations
    train_pred <- if (apply_boxcox) InvBoxCox(train_pred_scale, lambda) - shift else train_pred_scale; train_actual_raw <- if (apply_boxcox) InvBoxCox(train_actual, lambda) - shift else train_actual; test_pred <- if (apply_boxcox) InvBoxCox(test_pred_model, lambda) - shift else test_pred_model; test_pred_actual_lags <- if (apply_boxcox) InvBoxCox(test_pred_actual_lags_model, lambda) - shift else test_pred_actual_lags_model; train_pred <- pmax(train_pred, 0); test_pred <- pmax(test_pred, 0); test_pred_actual_lags <- pmax(test_pred_actual_lags, 0)
    train_metrics <- metric_table(train_actual_raw, train_pred, locations); test_metrics <- metric_table(test_raw, test_pred, locations); test_actual_lag_metrics <- metric_table(test_raw, test_pred_actual_lags, locations)
    for (j in seq_along(locations)) {
      png(file.path(plot_dir, paste0(split_name, "_fit_forecast_", tolower(locations[j]), ".png")), 1800, 850, res = 160)
      par(mfrow = c(1, 2), mar = c(4, 4, 3, 1))
      plot(train_actual_raw[, j], type = "l", col = "black", lwd = 2, xlab = "Training observation", ylab = "Rainfall", main = paste(locations[j], "training fit (", split_name, ")"))
      lines(train_pred[, j], col = "#1B72B8", lwd = 2); legend("topright", c("Actual", "Fitted"), col = c("black", "#1B72B8"), lty = 1, lwd = 2, bty = "n")
      plot(test_raw[, j], type = "l", col = "black", lwd = 2, xlab = "Hold-out observation", ylab = "Rainfall", main = paste(locations[j], "hold-out forecasts (", split_name, ")"))
      lines(test_pred[, j], col = "#D55E00", lwd = 2); lines(test_pred_actual_lags[, j], col = "#009E73", lwd = 2); legend("topright", c("Actual", "Recursive", "Actual-lag one-step"), col = c("black", "#D55E00", "#009E73"), lty = 1, lwd = 2, bty = "n")
      dev.off()
    }
    selected_params <- params[params$a == a & params$b == b, , drop = FALSE]; equation_terms <- if (engine == "custom") gstar_ab_equation_terms(fit) else gstar_package_equation_terms(fit)
    prefix <- file.path(result_dir, split_name); write.csv(variance_all, paste0(prefix, "_variance_stationarity.csv"), row.names = FALSE); write.csv(mean_all, paste0(prefix, "_mean_stationarity.csv"), row.names = FALSE); write.csv(ap, paste0(prefix, "_acf_pacf.csv"), row.names = FALSE); write.csv(cc, paste0(prefix, "_ccf.csv"), row.names = FALSE); write.csv(candidates, paste0(prefix, "_candidates.csv"), row.names = FALSE); write.csv(params, paste0(prefix, "_candidate_parameters.csv"), row.names = FALSE); write.csv(diags, paste0(prefix, "_candidate_iidn.csv"), row.names = FALSE); write.csv(corrs, paste0(prefix, "_candidate_residual_correlation.csv"), row.names = FALSE); write.csv(train_metrics, paste0(prefix, "_training_metrics.csv"), row.names = FALSE); write.csv(test_metrics, paste0(prefix, "_testing_metrics.csv"), row.names = FALSE); write.csv(test_metrics, paste0(prefix, "_testing_metrics_recursive.csv"), row.names = FALSE); write.csv(test_actual_lag_metrics, paste0(prefix, "_testing_metrics_actual_lags.csv"), row.names = FALSE); write.csv(equation_terms, paste0(prefix, "_selected_equation_terms.csv"), row.names = FALSE)
    summaries[[split_name]] <- data.frame(split = gsub("_", ":", split_name), train_rows = n_train, test_rows = nrow(test_raw), selected_model = paste0("GSTAR(", a, ",", b, ")"), differencing_d = d, selection_status = selection_status, AIC = candidates$AIC[selected], training_R_squared = train_metrics$R_squared[train_metrics$location == "Overall"], testing_R_squared = test_metrics$R_squared[test_metrics$location == "Overall"], testing_RMSE = test_metrics$RMSE[test_metrics$location == "Overall"])
    equation_note <- if (engine == "package") "Package convention: own-city terms are psi[k,0](i) Z[i,t-k]; spatial terms are psi[k,1](i) sum_j W[j,i] Z[j,t-k]." else "Custom convention: each city equation combines its own b lags and the inverse-distance-weighted other-city values through a lags."
    sections[[split_name]] <- c(paste0("## Split ", gsub("_", ":", split_name)), "", paste0("Training rows: ", n_train, "; test rows: ", nrow(test_raw), ". Selected **GSTAR(", a, ",", b, ")** with d = ", d, " (", selection_status, ")."), "", "### Stationarity", "", md_table(variance_all), "", md_table(mean_all), "", "### ACF/PACF and candidate lags", "", paste0("Own-city candidates: **", paste(own_lags, collapse = ", "), "**. Spatial candidates from absolute CCF peak magnitudes: **", paste(spatial_lags, collapse = ", "), "**."), "", md_table(ap), "", unlist(lapply(locations, function(loc) c(paste0("![ACF/PACF ", loc, "](plots_monthly_experiments/", tag, "/", split_name, "_acf_pacf_", tolower(loc), ".png)"), ""))), "### CCF", "", "Negative CCF lag means the second named location leads the first; positive lag means the first leads the second. The strongest correlation at each absolute non-zero lag is used to propose spatial-order candidates.", "", md_table(cc), "", unlist(lapply(ccf_pairs, function(pair) c(paste0("![CCF ", pair, "](plots_monthly_experiments/", tag, "/", split_name, "_ccf_", tolower(pair), ".png)"), ""))), "### Candidate models", "", md_table(candidates), "", "### Selected parameters", "", md_table(selected_params), "", "### Training fit and hold-out forecast", "", "Each panel compares actual rainfall with fitted values (left), recursive multi-step forecasts, and actual-lag one-step forecasts (right).", "", unlist(lapply(locations, function(loc) c(paste0("![Fit and forecast ", loc, "](plots_monthly_experiments/", tag, "/", split_name, "_fit_forecast_", tolower(loc), ".png)"), ""))), "### Training metrics", "", md_table(train_metrics), "", "### Testing metrics: recursive multi-step", "", "Each forecasted test value is used as a lag input for the next test forecast; no actual test value enters the forecast recursion.", "", md_table(test_metrics), "", "### Testing metrics: actual-lag one-step", "", "Each test prediction uses observed rainfall only from earlier test months as lag inputs; it does not use the current month’s actual rainfall. This is a one-step-ahead evaluation, not a deployable long-horizon forecast.", "", md_table(test_actual_lag_metrics), "", "### Selected residual diagnostics", "", md_table(diags[diags$a == a & diags$b == b, -c(1, 2), drop = FALSE]), "", "### Equation terms", "", equation_note, "", md_table(equation_terms), "")
  }
  summary <- do.call(rbind, summaries); write.csv(summary, file.path(result_dir, "split_comparison_summary.csv"), row.names = FALSE)
  limitation <- if (engine == "package") "The package accepts one temporal order p; therefore only equal-order GSTAR(a=p,b=p) candidates are fitted." else "The custom OLS fitter supports independent spatial order a and own-city order b."
  report <- c(paste0("# Monthly ", if (engine == "package") "Package GSTAR" else "Custom GSTAR(a,b)", " Experiments"), "", "## Experiment design", "", "Chronological 70:30, 80:20, and 90:10 splits are evaluated independently. All transformation, ADF, ACF/PACF, CCF, candidate selection, and fitting use training data only. Monthly diagnostic lags run through 36 months; peaks only are retained, up to six per dimension.", "", limitation, "", "## Split comparison", "", md_table(summary), "", unlist(sections), "## Reproducibility", "", paste0("Run `Rscript Week2/", if (engine == "package") "gstar_monthly_experiments.R" else "gstar_ab_monthly_experiments.R", "` in Docker."))
  writeLines(report, report_path); message("Monthly GSTAR experiments completed: ", report_path)
}
