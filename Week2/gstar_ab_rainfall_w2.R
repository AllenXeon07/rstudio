# GSTAR(a,b) rainfall analysis. Run: Rscript Week2/gstar_ab_rainfall_w2.R
suppressPackageStartupMessages({ library(forecast); library(tseries) })

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grepl("--file=", args)])
root <- if (length(script_path) && nchar(script_path)) normalizePath(dirname(script_path), mustWork = FALSE) else if (dir.exists("/home/rstudio/project/Week2")) "/home/rstudio/project/Week2" else getwd()
source(file.path(root, "gstar_ab.R"))
data_path <- file.path(root, "data", "rain_fall.csv")
coordinate_path <- file.path(root, "data", "station_coordinates.csv")
plot_dir <- file.path(root, "plots_rstudio_ab")
result_dir <- file.path(root, "results_ab")
report_path <- file.path(root, "gstar_ab_rainfall_w2_report.md")
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(result_dir, recursive = TRUE, showWarnings = FALSE)

rainfall <- read.csv(data_path, check.names = FALSE)
coordinates <- read.csv(coordinate_path, stringsAsFactors = FALSE)
locations <- names(rainfall)
if (ncol(rainfall) < 2L || any(!vapply(rainfall, is.numeric, logical(1))) || anyNA(rainfall)) stop("rain_fall.csv must contain complete numeric location columns.")
if (!identical(coordinates$location, locations) || anyNA(coordinates$latitude) || anyNA(coordinates$longitude)) stop("Coordinate names and order must exactly match rainfall columns.")
x <- as.matrix(rainfall); storage.mode(x) <- "double"; colnames(x) <- locations
n_total <- nrow(x); n_train <- floor(.8 * n_total); n_test <- n_total - n_train
train_raw <- x[seq_len(n_train), , drop = FALSE]; test_raw <- x[(n_train + 1L):n_total, , drop = FALSE]

haversine_km <- function(lat1, lon1, lat2, lon2) {
  radians <- pi / 180
  a <- sin((lat2 - lat1) * radians / 2)^2 + cos(lat1 * radians) * cos(lat2 * radians) * sin((lon2 - lon1) * radians / 2)^2
  12742 * atan2(sqrt(a), sqrt(1 - a))
}
distance_matrix <- outer(seq_along(locations), seq_along(locations), Vectorize(function(i, j) haversine_km(coordinates$latitude[i], coordinates$longitude[i], coordinates$latitude[j], coordinates$longitude[j])))
diag(distance_matrix) <- 0; dimnames(distance_matrix) <- list(locations, locations)
weights <- matrix(0, ncol(x), ncol(x), dimnames = list(locations, locations))
for (i in seq_len(nrow(weights))) { inverse_distance <- ifelse(seq_len(ncol(weights)) == i, 0, 1 / distance_matrix[i, ]); weights[i, ] <- inverse_distance / sum(inverse_distance) }
write.csv(coordinates, file.path(result_dir, "station_coordinates_used.csv"), row.names = FALSE)
write.csv(distance_matrix, file.path(result_dir, "station_distance_km.csv"), row.names = TRUE)
write.csv(weights, file.path(result_dir, "inverse_distance_weights.csv"), row.names = TRUE)

safe <- function(expr) tryCatch(expr, error = function(e) e)
stationarity <- function(values, stage) {
  variance <- do.call(rbind, lapply(seq_along(locations), function(j) {
    halves <- factor(rep(c("first_half", "second_half"), c(floor(nrow(values) / 2), ceiling(nrow(values) / 2))))
    test <- safe(fligner.test(values[, j] ~ halves))
    data.frame(stage = stage, location = locations[j], test = "Fligner-Killeen variance", lag = NA_integer_, statistic = if (inherits(test, "error")) NA_real_ else unname(test$statistic), p_value = if (inherits(test, "error")) NA_real_ else test$p.value, stationary = if (inherits(test, "error")) NA else test$p.value >= .05)
  }))
  adf <- do.call(rbind, lapply(seq_along(locations), function(j) do.call(rbind, lapply(0:12, function(k) {
    test <- safe(adf.test(values[, j], alternative = "stationary", k = k))
    data.frame(stage = stage, location = locations[j], test = "ADF", lag = k, statistic = if (inherits(test, "error")) NA_real_ else unname(test$statistic), p_value = if (inherits(test, "error")) NA_real_ else test$p.value, stationary = if (inherits(test, "error")) NA else test$p.value < .05)
  }))))
  kpss <- do.call(rbind, lapply(seq_along(locations), function(j) {
    test <- safe(kpss.test(values[, j], null = "Level"))
    data.frame(stage = stage, location = locations[j], test = "KPSS", lag = NA_integer_, statistic = if (inherits(test, "error")) NA_real_ else unname(test$statistic), p_value = if (inherits(test, "error")) NA_real_ else test$p.value, stationary = if (inherits(test, "error")) NA else test$p.value >= .05)
  }))
  list(variance = variance, mean = rbind(adf, kpss))
}
mean_stationary <- function(results) vapply(locations, function(name) {
  adf <- results[results$location == name & results$test == "ADF", , drop = FALSE]; kpss <- results[results$location == name & results$test == "KPSS", , drop = FALSE]
  mean(adf$stationary, na.rm = TRUE) >= .5 && length(kpss$stationary) == 1L && isTRUE(kpss$stationary)
}, logical(1))
plot_series <- function(values, title, filename, ylabel = "Rainfall") { png(file.path(plot_dir, filename), 1600, 900, res = 160); on.exit(dev.off(), add = TRUE); plot(seq_along(values), values, type = "l", lwd = 2, col = "#1F77B4", xlab = "Observation index", ylab = ylabel, main = title); grid(col = "grey85") }
for (j in seq_along(locations)) plot_series(train_raw[, j], paste("Training rainfall -", locations[j]), paste0("01_raw_timeseries_", tolower(locations[j]), ".png"))

raw_assessment <- stationarity(train_raw, "raw_training")
apply_boxcox <- any(!raw_assessment$variance$stationary, na.rm = TRUE)
lambda <- NA_real_; shift <- 0; train_model <- train_raw
if (apply_boxcox) { shift <- min(train_raw[train_raw > 0]) / 2; lambda <- BoxCox.lambda(as.numeric(train_raw + shift), method = "loglik"); train_model <- BoxCox(train_raw + shift, lambda); colnames(train_model) <- locations; for (j in seq_along(locations)) plot_series(train_model[, j], paste("Box-Cox training -", locations[j]), paste0("02_boxcox_", tolower(locations[j]), ".png"), "Box-Cox rainfall") }
transformed_assessment <- stationarity(train_model, if (apply_boxcox) "boxcox_training" else "raw_training_reused")
d <- if (all(mean_stationary(transformed_assessment$mean))) 0L else 1L
model_train <- if (d == 1L) diff(train_model) else train_model
if (d == 1L) { colnames(model_train) <- locations; for (j in seq_along(locations)) plot_series(model_train[, j], paste("First difference -", locations[j]), paste0("03_difference_", tolower(locations[j]), ".png"), "Differenced rainfall") }
difference_assessment <- if (d == 1L) stationarity(model_train, "first_difference_training") else NULL
variance_results <- rbind(raw_assessment$variance, transformed_assessment$variance); mean_results <- rbind(raw_assessment$mean, transformed_assessment$mean)
if (!is.null(difference_assessment)) { variance_results <- rbind(variance_results, difference_assessment$variance); mean_results <- rbind(mean_results, difference_assessment$mean) }
write.csv(variance_results, file.path(result_dir, "variance_stationarity.csv"), row.names = FALSE)
write.csv(mean_results, file.path(result_dir, "mean_stationarity_multiple_lags.csv"), row.names = FALSE)
write.csv(data.frame(boxcox_applied = apply_boxcox, boxcox_lambda = lambda, boxcox_shift = shift, difference_order_d = d), file.path(result_dir, "treatment_decision.csv"), row.names = FALSE)

max_identification_lag <- min(12L, floor(nrow(model_train) / 3L))
acf_pacf <- do.call(rbind, lapply(seq_along(locations), function(j) {
  series <- model_train[, j]; acf_values <- as.numeric(acf(series, plot = FALSE, lag.max = max_identification_lag)$acf[-1L]); pacf_values <- as.numeric(pacf(series, plot = FALSE, lag.max = max_identification_lag)$acf); bound <- qnorm(.975) / sqrt(length(series))
  data.frame(location = locations[j], lag = seq_len(max_identification_lag), acf = acf_values, pacf = pacf_values, significance_bound = bound, acf_significant = abs(acf_values) > bound, pacf_significant = abs(pacf_values) > bound)
}))
for (j in seq_along(locations)) { png(file.path(plot_dir, paste0("02_acf_pacf_", tolower(locations[j]), ".png")), 1600, 900, res = 160); par(mfrow = c(1, 2)); acf(model_train[, j], lag.max = max_identification_lag, main = paste("ACF -", locations[j])); pacf(model_train[, j], lag.max = max_identification_lag, main = paste("PACF -", locations[j])); dev.off() }
suggested_orders <- sort(unique(c(1L, acf_pacf$lag[acf_pacf$acf_significant], acf_pacf$lag[acf_pacf$pacf_significant])))
if (!length(suggested_orders)) suggested_orders <- 1L
write.csv(acf_pacf, file.path(result_dir, "acf_pacf_identification.csv"), row.names = FALSE)

candidate_pairs <- function(orders) expand.grid(a = orders, b = orders, KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
evaluate_candidates <- function(pairs, identification_round) {
  fits <- vector("list", nrow(pairs)); names(fits) <- paste(pairs$a, pairs$b, sep = "_")
  rows <- vector("list", nrow(pairs)); parameter_rows <- list(); iidn_rows <- list(); correlation_rows <- list()
  for (index in seq_len(nrow(pairs))) {
    a <- pairs$a[index]; b <- pairs$b[index]; fit <- safe(gstar_ab_fit(model_train, weights, a = a, b = b)); fits[[index]] <- fit
    if (inherits(fit, "error")) { rows[[index]] <- data.frame(a = a, b = b, identification_round = identification_round, fitted = FALSE, AIC = NA_real_, coefficients_finite = FALSE, error = conditionMessage(fit), iidn_pass = FALSE, white_noise_pass = FALSE); next }
    residual_matrix <- residuals(fit)
    diag_rows <- do.call(rbind, lapply(seq_along(locations), function(j) {
      residual <- residual_matrix[, j]; mean_test <- safe(t.test(residual, mu = 0)); shapiro <- safe(shapiro.test(residual)); groups <- factor(rep(c("first_half", "second_half"), c(floor(length(residual) / 2), ceiling(length(residual) / 2)))); variance_test <- safe(fligner.test(residual ~ groups)); lb10 <- safe(Box.test(residual, lag = min(10, length(residual) - 1L), type = "Ljung-Box")); lb20 <- safe(Box.test(residual, lag = min(20, length(residual) - 1L), type = "Ljung-Box"))
      data.frame(a = a, b = b, location = locations[j], mean_residual = mean(residual), residual_variance = var(residual), mean_zero_p_value = if (inherits(mean_test, "error")) NA_real_ else mean_test$p.value, normality_shapiro_p_value = if (inherits(shapiro, "error")) NA_real_ else shapiro$p.value, variance_stability_fligner_p_value = if (inherits(variance_test, "error")) NA_real_ else variance_test$p.value, ljung_box_10_p_value = if (inherits(lb10, "error")) NA_real_ else lb10$p.value, ljung_box_20_p_value = if (inherits(lb20, "error")) NA_real_ else lb20$p.value)
    }))
    iidn_rows[[length(iidn_rows) + 1L]] <- diag_rows
    iidn_pass <- all(diag_rows$mean_zero_p_value >= .05 & diag_rows$normality_shapiro_p_value >= .05 & diag_rows$variance_stability_fligner_p_value >= .05 & diag_rows$ljung_box_10_p_value >= .05 & diag_rows$ljung_box_20_p_value >= .05)
    white_noise_pass <- all(diag_rows$mean_zero_p_value >= .05 & diag_rows$variance_stability_fligner_p_value >= .05 & diag_rows$ljung_box_10_p_value >= .05 & diag_rows$ljung_box_20_p_value >= .05)
    parameter_rows[[length(parameter_rows) + 1L]] <- data.frame(a = a, b = b, parameter = names(fit$coefficients), estimate = as.numeric(fit$coefficients), std_error = as.numeric(fit$std_error), t_value = as.numeric(fit$t_value), p_value = as.numeric(fit$p_value))
    corr <- cor(residual_matrix); grid <- expand.grid(location_1 = locations, location_2 = locations, stringsAsFactors = FALSE); correlation_rows[[length(correlation_rows) + 1L]] <- data.frame(a = a, b = b, grid, correlation = as.vector(corr))
    rows[[index]] <- data.frame(a = a, b = b, identification_round = identification_round, fitted = TRUE, AIC = fit$AIC, coefficients_finite = all(is.finite(fit$coefficients)), error = "", min_mean_zero_p = min(diag_rows$mean_zero_p_value), min_normality_p = min(diag_rows$normality_shapiro_p_value), min_variance_stability_p = min(diag_rows$variance_stability_fligner_p_value), min_ljung_box_10_p = min(diag_rows$ljung_box_10_p_value), min_ljung_box_20_p = min(diag_rows$ljung_box_20_p_value), iidn_pass = iidn_pass, white_noise_pass = white_noise_pass)
  }
  list(fits = fits, candidates = do.call(rbind, rows), parameters = do.call(rbind, parameter_rows), iidn = do.call(rbind, iidn_rows), correlations = do.call(rbind, correlation_rows))
}
initial_pairs <- candidate_pairs(suggested_orders); initial <- evaluate_candidates(initial_pairs, "ACF/PACF suggestion")
adequate_initial <- initial$candidates$fitted & initial$candidates$coefficients_finite & initial$candidates$iidn_pass
all_pairs <- candidate_pairs(seq_len(max_identification_lag)); initial_key <- paste(initial_pairs$a, initial_pairs$b); remaining_pairs <- all_pairs[!paste(all_pairs$a, all_pairs$b) %in% initial_key, , drop = FALSE]
expanded <- if (!any(adequate_initial) && nrow(remaining_pairs)) evaluate_candidates(remaining_pairs, "diagnostic-driven re-identification") else NULL
fits <- c(initial$fits, if (!is.null(expanded)) expanded$fits else list())
candidates <- rbind(initial$candidates, if (!is.null(expanded)) expanded$candidates else NULL)
candidate_parameters <- rbind(initial$parameters, if (!is.null(expanded)) expanded$parameters else NULL)
candidate_iidn <- rbind(initial$iidn, if (!is.null(expanded)) expanded$iidn else NULL)
candidate_correlations <- rbind(initial$correlations, if (!is.null(expanded)) expanded$correlations else NULL)
write.csv(candidates, file.path(result_dir, "candidate_model_comparison.csv"), row.names = FALSE); write.csv(candidate_parameters, file.path(result_dir, "candidate_parameter_estimates.csv"), row.names = FALSE); write.csv(candidate_iidn, file.path(result_dir, "candidate_iidn_diagnostics.csv"), row.names = FALSE); write.csv(candidate_correlations, file.path(result_dir, "candidate_residual_correlations.csv"), row.names = FALSE)
if (!any(candidates$fitted)) stop("All GSTAR(a,b) fits failed.")
full_ok <- candidates$fitted & candidates$coefficients_finite & candidates$iidn_pass; white_ok <- candidates$fitted & candidates$coefficients_finite & candidates$white_noise_pass
selected_index <- if (any(full_ok)) which.min(ifelse(full_ok, candidates$AIC, Inf)) else if (any(white_ok)) which.min(ifelse(white_ok, candidates$AIC, Inf)) else which.min(ifelse(candidates$fitted & candidates$coefficients_finite, candidates$AIC, Inf))
selected_a <- candidates$a[selected_index]; selected_b <- candidates$b[selected_index]; selected_key <- paste(selected_a, selected_b, sep = "_"); fit <- fits[[selected_key]]
coefficients <- data.frame(parameter = names(fit$coefficients), estimate = as.numeric(fit$coefficients), std_error = as.numeric(fit$std_error), t_value = as.numeric(fit$t_value), p_value = as.numeric(fit$p_value)); equation_terms <- gstar_ab_equation_terms(fit)
write.csv(coefficients, file.path(result_dir, "selected_model_coefficients.csv"), row.names = FALSE); write.csv(equation_terms, file.path(result_dir, "selected_model_equation_terms.csv"), row.names = FALSE)

residuals_matrix <- residuals(fit); diagnostics <- candidate_iidn[candidate_iidn$a == selected_a & candidate_iidn$b == selected_b, -c(1, 2), drop = FALSE]
write.csv(diagnostics, file.path(result_dir, "residual_diagnostics.csv"), row.names = FALSE); write.csv(cor(residuals_matrix), file.path(result_dir, "residual_cross_location_correlation.csv"), row.names = TRUE)
for (j in seq_along(locations)) { png(file.path(plot_dir, paste0("04_residual_diagnostics_", tolower(locations[j]), ".png")), 1600, 900, res = 160); par(mfrow = c(1, 2)); plot(residuals_matrix[, j], type = "l", main = paste("Residuals -", locations[j]), xlab = "Model observation", ylab = "Residual"); abline(h = 0, lty = 2, col = "red"); acf(residuals_matrix[, j], main = paste("Residual ACF -", locations[j])); dev.off() }

predicted_model <- predict(fit, n.ahead = n_test)
if (d == 1L) { predicted_model <- apply(predicted_model, 2, function(v) cumsum(v) + tail(train_model[, colnames(predicted_model) == names(v)], 1)); predicted_model <- as.matrix(predicted_model); colnames(predicted_model) <- locations }
predicted_raw <- if (apply_boxcox) InvBoxCox(predicted_model, lambda) - shift else predicted_model; predicted_raw <- pmax(predicted_raw, 0)
metrics_by_location <- do.call(rbind, lapply(seq_along(locations), function(j) { actual <- test_raw[, j]; predicted <- predicted_raw[, j]; nonzero <- actual != 0; data.frame(location = locations[j], MSE = mean((actual - predicted)^2), RMSE = sqrt(mean((actual - predicted)^2)), MAE = mean(abs(actual - predicted)), sMAPE = mean(200 * abs(actual - predicted) / (abs(actual) + abs(predicted) + .Machine$double.eps)), MAPE_nonzero = if (any(nonzero)) mean(abs((actual[nonzero] - predicted[nonzero]) / actual[nonzero])) * 100 else NA_real_) }))
metrics <- rbind(metrics_by_location, data.frame(location = "Overall", MSE = mean((test_raw - predicted_raw)^2), RMSE = sqrt(mean((test_raw - predicted_raw)^2)), MAE = mean(abs(test_raw - predicted_raw)), sMAPE = mean(200 * abs(test_raw - predicted_raw) / (abs(test_raw) + abs(predicted_raw) + .Machine$double.eps)), MAPE_nonzero = mean(abs((test_raw[test_raw != 0] - predicted_raw[test_raw != 0]) / test_raw[test_raw != 0])) * 100))
write.csv(metrics, file.path(result_dir, "test_metrics.csv"), row.names = FALSE)
test_predictions <- data.frame(observation = rep(n_train + seq_len(n_test), times = length(locations)), location = rep(locations, each = n_test), actual = as.vector(test_raw), predicted = as.vector(predicted_raw)); write.csv(test_predictions, file.path(result_dir, "test_actual_vs_predicted.csv"), row.names = FALSE)
for (j in seq_along(locations)) { png(file.path(plot_dir, paste0("05_test_forecast_", tolower(locations[j]), ".png")), 1600, 900, res = 160); plot((n_train + 1L):n_total, test_raw[, j], type = "l", lwd = 2, col = "#1F77B4", xlab = "Observation index", ylab = "Rainfall", main = paste("20% hold-out forecast -", locations[j])); lines((n_train + 1L):n_total, predicted_raw[, j], lwd = 2, col = "#D62728"); legend("topright", c("Actual", "GSTAR(a,b) forecast"), col = c("#1F77B4", "#D62728"), lty = 1, lwd = 2, bty = "n"); grid(col = "grey85"); dev.off() }

markdown_table <- function(tab, digits = 6L) { display <- as.data.frame(tab, check.names = FALSE); display[] <- lapply(display, function(value) if (is.numeric(value)) format(round(value, digits), trim = TRUE, scientific = FALSE) else as.character(value)); c(paste0("| ", paste(names(display), collapse = " | "), " |"), paste0("|", paste(rep("---", ncol(display)), collapse = "|"), "|"), apply(display, 1, function(row) paste0("| ", paste(row, collapse = " | "), " |"))) }
format_equation <- function(location) { terms <- equation_terms[equation_terms$location == location, , drop = FALSE]; term_text <- paste0(formatC(abs(terms$coefficient), format = "f", digits = 6), " Z_{\\text{", terms$source_location, "},t-", terms$lag, "}"); signed <- c(if (terms$coefficient[1] < 0) paste0("-", term_text[1]) else term_text[1], ifelse(terms$coefficient[-1] < 0, paste0(" - ", term_text[-1]), paste0(" + ", term_text[-1]))); paste0("$$ Z_{\\text{", location, "},t} = ", paste0(signed, collapse = ""), " + \\varepsilon_{\\text{", location, "},t}. $$") }
final_equations <- unlist(lapply(locations, function(name) c(paste0("### ", name), "", format_equation(name), "")))
distance_report <- data.frame(location = rownames(distance_matrix), distance_matrix, check.names = FALSE); weight_report <- data.frame(location = rownames(weights), weights, check.names = FALSE); residual_correlation_report <- data.frame(location = rownames(cor(residuals_matrix)), cor(residuals_matrix), check.names = FALSE)
report <- c(
  "# GSTAR(a,b) Analysis of Rainfall at Juanda, Perak1, and Perak2", "", "## Pipeline recap", "",
  paste0("The first ", n_train, " rows are training data and the final ", n_test, " rows are the untouched 20% chronological test set."), "",
  "1. Read and validate rainfall plus station coordinates.", "2. Build inverse-distance spatial weights.", "3. Plot training data and check variance/mean stationarity.", "4. Apply Box-Cox only when variance is non-stationary; difference only when mean remains non-stationary.", "5. Use ACF/PACF to propose multiple GSTAR(a,b) candidates.", "6. Fit candidates by custom OLS, diagnose residuals, and expand identification if none passes full IIDN.", "7. Forecast the untouched test data.", "",
  "## 1. Coordinates, distances, and spatial weights", "", "### Input coordinates", "", markdown_table(coordinates), "", "### Haversine distance matrix (km)", "", markdown_table(distance_report), "", "### Row-standardized inverse-distance matrix", "", markdown_table(weight_report), "",
  "## 2. Raw training plots", "", unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Raw training series](plots_rstudio_ab/01_raw_timeseries_", tolower(name), ".png)"), ""))),
  "## 3. Stationarity checks and treatment decision", "", paste0("**Decision:** Box-Cox = ", apply_boxcox, "; lambda = ", round(lambda, 6), "; shift = ", round(shift, 6), "; differencing order d = ", d, "."), "", "### All variance-stationarity results", "", markdown_table(variance_results), "", "### All mean-stationarity results", "", markdown_table(mean_results), "",
  "## 4. ACF/PACF identification and diagnostic iteration", "", paste0("For each station, ACF/PACF was calculated to lag ", max_identification_lag, ". Initial lag suggestions are: **", paste(suggested_orders, collapse = ", "), "**. Every pair (a,b) from these suggestions is fitted, where a is the maximum weighted-other-location lag and b is the maximum own-location lag. If no suggested pair passes full IIDN, remaining pairs through the identification limit are evaluated."), "", "### ACF/PACF values", "", markdown_table(acf_pacf), "", unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![ACF/PACF - ", name, "](plots_rstudio_ab/02_acf_pacf_", tolower(name), ".png)"), ""))), "### Candidate summary and selection flags", "", markdown_table(candidates), "", "### All candidate parameter estimates", "", markdown_table(candidate_parameters), "", "### All candidate IIDN diagnostics", "", markdown_table(candidate_iidn), "", "### All candidate residual cross-location correlations", "", markdown_table(candidate_correlations), "",
  "## 5. Selected GSTAR(a,b) model", "", paste0("Selected model: **GSTAR(", selected_a, ", ", selected_b, ")**; differencing order: **d = ", d, "**."), "", "### All parameter estimates", "", markdown_table(coefficients), "", "### Final equations by location", "", final_equations, "### Expanded equation terms", "", markdown_table(equation_terms), "",
  "## 6. IIDN residual diagnostics", "", "IIDN is assessed using residual mean, normality, variance stability, and Ljung-Box tests. Residual cross-location correlation is also reported.", "", "### All IIDN diagnostic results", "", markdown_table(diagnostics), "", "### Residual cross-location correlation", "", markdown_table(residual_correlation_report), "", unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Residual diagnostics - ", name, "](plots_rstudio_ab/04_residual_diagnostics_", tolower(name), ".png)"), ""))),
  "## 7. Untouched 20% test evaluation", "", "### All test metrics", "", markdown_table(metrics), "", "### All actual-versus-predicted test observations", "", markdown_table(test_predictions), "", unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Hold-out forecast - ", name, "](plots_rstudio_ab/05_test_forecast_", tolower(name), ".png)"), ""))),
  "## Reproducibility", "", "Run `Rscript Week2/gstar_ab_rainfall_w2.R` in Docker. This script imports `gstar_ab.R`; source rainfall data are read only."
)
writeLines(report, report_path)
message("GSTAR(a,b) workflow completed. Report: ", report_path)
