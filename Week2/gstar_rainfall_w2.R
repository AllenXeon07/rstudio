# GSTAR rainfall analysis. Run: Rscript /home/rstudio/project/Week2/gstar_rainfall_w2.R
suppressPackageStartupMessages({ library(forecast); library(tseries); library(gstar) })

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grepl("--file=", args)])
root <- if (length(script_path) && nchar(script_path)) normalizePath(dirname(script_path), mustWork = FALSE) else if (dir.exists("/home/rstudio/project/Week2")) "/home/rstudio/project/Week2" else getwd()
data_path <- file.path(root, "data", "rain_fall.csv")
coordinate_path <- file.path(root, "data", "station_coordinates.csv")
plot_dir <- file.path(root, "plots_rstudio")
result_dir <- file.path(root, "results")
report_path <- file.path(root, "gstar_rainfall_w2_report.md")
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(result_dir, recursive = TRUE, showWarnings = FALSE)

rainfall <- read.csv(data_path, check.names = FALSE)
coordinates <- read.csv(coordinate_path, stringsAsFactors = FALSE)
locations <- names(rainfall)
if (ncol(rainfall) < 2L || any(!vapply(rainfall, is.numeric, logical(1))) || anyNA(rainfall)) stop("rain_fall.csv must contain complete numeric location columns.")
if (!identical(coordinates$location, locations) || anyNA(coordinates$latitude) || anyNA(coordinates$longitude)) stop("Coordinate names and order must exactly match rainfall columns.")
x <- as.matrix(rainfall); storage.mode(x) <- "double"
n_total <- nrow(x); n_train <- floor(0.8 * n_total); n_test <- n_total - n_train
train_raw <- x[seq_len(n_train), , drop = FALSE]
test_raw <- x[(n_train + 1L):n_total, , drop = FALSE]

haversine_km <- function(lat1, lon1, lat2, lon2) {
  radians <- pi / 180
  a <- sin((lat2 - lat1) * radians / 2)^2 + cos(lat1 * radians) * cos(lat2 * radians) * sin((lon2 - lon1) * radians / 2)^2
  12742 * atan2(sqrt(a), sqrt(1 - a))
}
distance_matrix <- outer(seq_along(locations), seq_along(locations), Vectorize(function(i, j) haversine_km(coordinates$latitude[i], coordinates$longitude[i], coordinates$latitude[j], coordinates$longitude[j])))
diag(distance_matrix) <- 0
dimnames(distance_matrix) <- list(locations, locations)
weights <- matrix(0, ncol(x), ncol(x), dimnames = list(locations, locations))
for (i in seq_len(nrow(weights))) {
  inverse_distance <- ifelse(seq_len(ncol(weights)) == i, 0, 1 / distance_matrix[i, ])
  weights[i, ] <- inverse_distance / sum(inverse_distance)
}
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
  adf <- results[results$location == name & results$test == "ADF", , drop = FALSE]
  kpss <- results[results$location == name & results$test == "KPSS", , drop = FALSE]
  mean(adf$stationary, na.rm = TRUE) >= .5 && length(kpss$stationary) == 1L && isTRUE(kpss$stationary)
}, logical(1))
plot_series <- function(values, title, filename, ylabel = "Rainfall") {
  png(file.path(plot_dir, filename), 1600, 900, res = 160)
  on.exit(dev.off(), add = TRUE)
  plot(seq_along(values), values, type = "l", lwd = 2, col = "#1F77B4", xlab = "Observation index", ylab = ylabel, main = title)
  grid(col = "grey85")
}
for (j in seq_along(locations)) plot_series(train_raw[, j], paste("Training rainfall -", locations[j]), paste0("01_raw_timeseries_", tolower(locations[j]), ".png"))

# Raw data are assessed first; no transformation occurs before this point.
raw_assessment <- stationarity(train_raw, "raw_training")
apply_boxcox <- any(!raw_assessment$variance$stationary, na.rm = TRUE)
lambda <- NA_real_; shift <- 0; train_model <- train_raw; test_model <- test_raw
if (apply_boxcox) {
  shift <- min(train_raw[train_raw > 0]) / 2
  lambda <- BoxCox.lambda(as.numeric(train_raw + shift), method = "loglik")
  train_model <- BoxCox(train_raw + shift, lambda)
  test_model <- BoxCox(test_raw + shift, lambda)
  for (j in seq_along(locations)) plot_series(train_model[, j], paste("Box-Cox training series -", locations[j]), paste0("02_boxcox_", tolower(locations[j]), ".png"), "Box-Cox rainfall")
}
transformed_assessment <- stationarity(train_model, if (apply_boxcox) "boxcox_training" else "raw_training_reused")
d <- if (all(mean_stationary(transformed_assessment$mean))) 0L else 1L
difference_assessment <- if (d == 1L) stationarity(diff(train_model), "first_difference_training") else NULL
if (d == 1L) for (j in seq_along(locations)) plot_series(diff(train_model[, j]), paste("First-differenced training -", locations[j]), paste0("03_difference_", tolower(locations[j]), ".png"), "Differenced rainfall")
variance_results <- rbind(raw_assessment$variance, transformed_assessment$variance)
mean_results <- rbind(raw_assessment$mean, transformed_assessment$mean)
if (!is.null(difference_assessment)) { variance_results <- rbind(variance_results, difference_assessment$variance); mean_results <- rbind(mean_results, difference_assessment$mean) }
write.csv(variance_results, file.path(result_dir, "variance_stationarity.csv"), row.names = FALSE)
write.csv(mean_results, file.path(result_dir, "mean_stationarity_multiple_lags.csv"), row.names = FALSE)
write.csv(data.frame(boxcox_applied = apply_boxcox, boxcox_lambda = lambda, boxcox_shift = shift, GSTAR_difference_order = d), file.path(result_dir, "treatment_decision.csv"), row.names = FALSE)

candidate_orders <- 1:12
fits <- lapply(candidate_orders, function(p) safe(gstar::gstar(train_model, weight = weights, p = p, d = d, est = "OLS")))
candidate_iidn <- do.call(rbind, lapply(seq_along(candidate_orders), function(index) {
  candidate_fit <- fits[[index]]
  if (inherits(candidate_fit, "error")) return(NULL)
  fitted_candidate <- as.matrix(candidate_fit$fitted_values)
  observed_candidate <- train_model[(n_train - nrow(fitted_candidate) + 1L):n_train, , drop = FALSE]
  residual_candidate <- observed_candidate - fitted_candidate
  do.call(rbind, lapply(seq_along(locations), function(j) {
    residual <- residual_candidate[, j]
    mean_test <- safe(t.test(residual, mu = 0))
    normality_test <- safe(shapiro.test(residual))
    groups <- factor(rep(c("first_half", "second_half"), c(floor(length(residual) / 2), ceiling(length(residual) / 2))))
    variance_test <- safe(fligner.test(residual ~ groups))
    lb10 <- safe(Box.test(residual, lag = min(10, length(residual) - 1L), type = "Ljung-Box"))
    lb20 <- safe(Box.test(residual, lag = min(20, length(residual) - 1L), type = "Ljung-Box"))
    data.frame(p = candidate_orders[index], location = locations[j], mean_residual = mean(residual), residual_variance = var(residual), mean_zero_p_value = if (inherits(mean_test, "error")) NA_real_ else mean_test$p.value, normality_shapiro_p_value = if (inherits(normality_test, "error")) NA_real_ else normality_test$p.value, variance_stability_fligner_p_value = if (inherits(variance_test, "error")) NA_real_ else variance_test$p.value, ljung_box_10_p_value = if (inherits(lb10, "error")) NA_real_ else lb10$p.value, ljung_box_20_p_value = if (inherits(lb20, "error")) NA_real_ else lb20$p.value)
  }))
}))
candidate_parameters <- do.call(rbind, lapply(seq_along(candidate_orders), function(index) {
  candidate_fit <- fits[[index]]
  if (inherits(candidate_fit, "error")) return(NULL)
  parameter_names <- rownames(candidate_fit$B)
  if (is.null(parameter_names) || length(parameter_names) != length(candidate_fit$B)) parameter_names <- paste0("parameter_", seq_along(candidate_fit$B))
  data.frame(p = candidate_orders[index], parameter = parameter_names, estimate = as.numeric(candidate_fit$B), std_error = as.numeric(candidate_fit$std_err), t_value = as.numeric(candidate_fit$t_value), p_value = as.numeric(candidate_fit$p_value))
}))
candidate_residual_correlations <- do.call(rbind, lapply(seq_along(candidate_orders), function(index) {
  candidate_fit <- fits[[index]]
  if (inherits(candidate_fit, "error")) return(NULL)
  fitted_candidate <- as.matrix(candidate_fit$fitted_values)
  observed_candidate <- train_model[(n_train - nrow(fitted_candidate) + 1L):n_train, , drop = FALSE]
  correlation <- cor(observed_candidate - fitted_candidate)
  grid <- expand.grid(location_1 = locations, location_2 = locations, stringsAsFactors = FALSE)
  data.frame(p = candidate_orders[index], grid, correlation = as.vector(correlation))
}))
candidate_iidn_summary <- do.call(rbind, lapply(candidate_orders, function(order) {
  diagnostic <- candidate_iidn[candidate_iidn$p == order, , drop = FALSE]
  data.frame(p = order, min_mean_zero_p = min(diagnostic$mean_zero_p_value, na.rm = TRUE), min_normality_p = min(diagnostic$normality_shapiro_p_value, na.rm = TRUE), min_variance_stability_p = min(diagnostic$variance_stability_fligner_p_value, na.rm = TRUE), min_ljung_box_10_p = min(diagnostic$ljung_box_10_p_value, na.rm = TRUE), min_ljung_box_20_p = min(diagnostic$ljung_box_20_p_value, na.rm = TRUE), iidn_pass = all(diagnostic$mean_zero_p_value >= .05 & diagnostic$normality_shapiro_p_value >= .05 & diagnostic$variance_stability_fligner_p_value >= .05 & diagnostic$ljung_box_10_p_value >= .05 & diagnostic$ljung_box_20_p_value >= .05), white_noise_pass = all(diagnostic$mean_zero_p_value >= .05 & diagnostic$variance_stability_fligner_p_value >= .05 & diagnostic$ljung_box_10_p_value >= .05 & diagnostic$ljung_box_20_p_value >= .05))
}))
candidate_diagnostic <- function(candidate_fit) {
  if (inherits(candidate_fit, "error")) return(c(coefficients_finite = FALSE, min_ljung_box_p = NA_real_))
  fitted_candidate <- as.matrix(candidate_fit$fitted_values)
  observed_candidate <- train_model[(n_train - nrow(fitted_candidate) + 1L):n_train, , drop = FALSE]
  residual_candidate <- observed_candidate - fitted_candidate
  p_values <- vapply(seq_len(ncol(residual_candidate)), function(j) {
    test <- safe(Box.test(residual_candidate[, j], lag = min(20, nrow(residual_candidate) - 1L), type = "Ljung-Box"))
    if (inherits(test, "error")) NA_real_ else test$p.value
  }, numeric(1))
  c(coefficients_finite = all(is.finite(candidate_fit$B)), min_ljung_box_p = min(p_values, na.rm = TRUE))
}
candidates <- do.call(rbind, lapply(seq_along(candidate_orders), function(index) {
  fit <- fits[[index]]
  diagnostic <- candidate_diagnostic(fit)
  data.frame(p = candidate_orders[index], d = d, fitted = !inherits(fit, "error"), AIC = if (inherits(fit, "error")) NA_real_ else fit$AIC, coefficients_finite = as.logical(diagnostic["coefficients_finite"]), min_ljung_box_p = as.numeric(diagnostic["min_ljung_box_p"]), error = if (inherits(fit, "error")) conditionMessage(fit) else "")
}))
candidates <- merge(candidates, candidate_iidn_summary, by = "p", all.x = TRUE, sort = FALSE)
write.csv(candidate_iidn, file.path(result_dir, "candidate_iidn_diagnostics.csv"), row.names = FALSE)
write.csv(candidate_parameters, file.path(result_dir, "candidate_parameter_estimates.csv"), row.names = FALSE)
write.csv(candidate_residual_correlations, file.path(result_dir, "candidate_residual_correlations.csv"), row.names = FALSE)
write.csv(candidates, file.path(result_dir, "candidate_model_comparison.csv"), row.names = FALSE)
if (!any(candidates$fitted)) stop("All GSTAR fits failed; see results/candidate_model_comparison.csv.")
diagnostically_adequate <- candidates$fitted & candidates$coefficients_finite & candidates$iidn_pass
white_noise_adequate <- candidates$fitted & candidates$coefficients_finite & candidates$white_noise_pass
selected_index <- if (any(diagnostically_adequate)) which.min(ifelse(diagnostically_adequate, candidates$AIC, Inf)) else if (any(white_noise_adequate)) which.min(ifelse(white_noise_adequate, candidates$AIC, Inf)) else which.min(ifelse(candidates$fitted & candidates$coefficients_finite, candidates$AIC, Inf))
selected_order <- candidate_orders[selected_index]
fit <- fits[[selected_index]]
parameter_names <- rownames(fit$B)
if (is.null(parameter_names) || length(parameter_names) != length(fit$B)) parameter_names <- paste0("parameter_", seq_along(fit$B))
coefficients <- data.frame(parameter = parameter_names, estimate = as.numeric(fit$B), std_error = as.numeric(fit$std_err), t_value = as.numeric(fit$t_value), p_value = as.numeric(fit$p_value))
write.csv(coefficients, file.path(result_dir, "selected_model_coefficients.csv"), row.names = FALSE)

fitted_values <- as.matrix(fit$fitted_values)
actual_fit <- train_model[(n_train - nrow(fitted_values) + 1L):n_train, , drop = FALSE]
residuals_matrix <- actual_fit - fitted_values
diagnostics <- do.call(rbind, lapply(seq_along(locations), function(j) {
  residual <- residuals_matrix[, j]
  shapiro <- safe(shapiro.test(residual))
  mean_test <- safe(t.test(residual, mu = 0))
  variance_groups <- factor(rep(c("first_half", "second_half"), c(floor(length(residual) / 2), ceiling(length(residual) / 2))))
  variance_test <- safe(fligner.test(residual ~ variance_groups))
  lb10 <- safe(Box.test(residual, lag = min(10, length(residual) - 1L), type = "Ljung-Box"))
  lb20 <- safe(Box.test(residual, lag = min(20, length(residual) - 1L), type = "Ljung-Box"))
  data.frame(location = locations[j], mean_residual = mean(residual), residual_variance = var(residual), mean_zero_p_value = if (inherits(mean_test, "error")) NA_real_ else mean_test$p.value, normality_shapiro_p_value = if (inherits(shapiro, "error")) NA_real_ else shapiro$p.value, variance_stability_fligner_p_value = if (inherits(variance_test, "error")) NA_real_ else variance_test$p.value, ljung_box_10_p_value = if (inherits(lb10, "error")) NA_real_ else lb10$p.value, ljung_box_20_p_value = if (inherits(lb20, "error")) NA_real_ else lb20$p.value)
}))
write.csv(diagnostics, file.path(result_dir, "residual_diagnostics.csv"), row.names = FALSE)
write.csv(cor(residuals_matrix), file.path(result_dir, "residual_cross_location_correlation.csv"), row.names = TRUE)
for (j in seq_along(locations)) {
  png(file.path(plot_dir, paste0("04_residual_diagnostics_", tolower(locations[j]), ".png")), 1600, 900, res = 160)
  par(mfrow = c(1, 2)); plot(residuals_matrix[, j], type = "l", main = paste("Residuals -", locations[j]), xlab = "Model observation", ylab = "Residual"); abline(h = 0, lty = 2, col = "red"); acf(residuals_matrix[, j], main = paste("Residual ACF -", locations[j])); dev.off()
}

predicted_model <- as.matrix(predict(fit, n = n_test))
if (nrow(predicted_model) != n_test) stop("GSTAR prediction length does not match testing data.")
colnames(predicted_model) <- locations
predicted_raw <- if (apply_boxcox) InvBoxCox(predicted_model, lambda) - shift else predicted_model
predicted_raw <- pmax(predicted_raw, 0)
metrics_by_location <- do.call(rbind, lapply(seq_along(locations), function(j) {
  actual <- test_raw[, j]; predicted <- predicted_raw[, j]; nonzero <- actual != 0
  data.frame(location = locations[j], MSE = mean((actual - predicted)^2), RMSE = sqrt(mean((actual - predicted)^2)), MAE = mean(abs(actual - predicted)), sMAPE = mean(200 * abs(actual - predicted) / (abs(actual) + abs(predicted) + .Machine$double.eps)), MAPE_nonzero = if (any(nonzero)) mean(abs((actual[nonzero] - predicted[nonzero]) / actual[nonzero])) * 100 else NA_real_)
}))
metrics <- rbind(metrics_by_location, data.frame(location = "Overall", MSE = mean((test_raw - predicted_raw)^2), RMSE = sqrt(mean((test_raw - predicted_raw)^2)), MAE = mean(abs(test_raw - predicted_raw)), sMAPE = mean(200 * abs(test_raw - predicted_raw) / (abs(test_raw) + abs(predicted_raw) + .Machine$double.eps)), MAPE_nonzero = mean(abs((test_raw[test_raw != 0] - predicted_raw[test_raw != 0]) / test_raw[test_raw != 0])) * 100))
write.csv(metrics, file.path(result_dir, "test_metrics.csv"), row.names = FALSE)
test_predictions <- data.frame(observation = rep(n_train + seq_len(n_test), times = length(locations)), location = rep(locations, each = n_test), actual = as.vector(test_raw), predicted = as.vector(predicted_raw))
write.csv(test_predictions, file.path(result_dir, "test_actual_vs_predicted.csv"), row.names = FALSE)
for (j in seq_along(locations)) {
  png(file.path(plot_dir, paste0("05_test_forecast_", tolower(locations[j]), ".png")), 1600, 900, res = 160)
  plot((n_train + 1L):n_total, test_raw[, j], type = "l", lwd = 2, col = "#1F77B4", xlab = "Observation index", ylab = "Rainfall", main = paste("20% hold-out forecast -", locations[j])); lines((n_train + 1L):n_total, predicted_raw[, j], lwd = 2, col = "#D62728"); legend("topright", c("Actual", "GSTAR forecast"), col = c("#1F77B4", "#D62728"), lty = 1, lwd = 2, bty = "n"); grid(col = "grey85"); dev.off()
}

markdown_table <- function(tab, digits = 6L) {
  display <- as.data.frame(tab, check.names = FALSE)
  display[] <- lapply(display, function(value) if (is.numeric(value)) format(round(value, digits), trim = TRUE, scientific = FALSE) else as.character(value))
  header <- paste0("| ", paste(names(display), collapse = " | "), " |")
  separator <- paste0("|", paste(rep("---", ncol(display)), collapse = "|"), "|")
  rows <- apply(display, 1, function(row) paste0("| ", paste(row, collapse = " | "), " |"))
  c(header, separator, rows)
}
distance_report <- data.frame(location = rownames(distance_matrix), distance_matrix, check.names = FALSE)
weight_report <- data.frame(location = rownames(weights), weights, check.names = FALSE)
residual_correlation_report <- data.frame(location = rownames(cor(residuals_matrix)), cor(residuals_matrix), check.names = FALSE)
report <- c(
  "# GSTAR Analysis of Rainfall at Juanda, Perak1, and Perak2", "",
  "## Pipeline recap", "",
  paste0("The first ", n_train, " rows are training data and the final ", n_test, " rows are the untouched 20% chronological test set. The data frequency is unknown, so all lags are observation lags."), "",
  "1. Read and validate rainfall plus station coordinates.",
  "2. Build inverse-distance spatial weights.",
  "3. Plot raw training data and check variance/mean stationarity.",
  "4. Apply Box–Cox only if variance is non-stationary; difference only if mean remains non-stationary.",
  "5. Fit GSTAR candidates, diagnose residuals, then evaluate the untouched test data.", "",
  "## 1. Coordinates, distances, and spatial weights", "", "### Input coordinates", "", markdown_table(coordinates), "",
  "### Haversine distance matrix (km)", "", markdown_table(distance_report), "",
  "### Row-standardized inverse-distance matrix", "", markdown_table(weight_report), "",
  "## 2. Raw training plots", "", unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Raw training series](plots_rstudio/01_raw_timeseries_", tolower(name), ".png)"), ""))),
  "## 3. Stationarity checks and treatment decision", "",
  "Raw variance was tested before transformation. Box–Cox is used only when variance stationarity is rejected; first differencing is used only when mean stationarity remains unsupported by ADF (lags 0–12) and KPSS.", "",
  paste0("**Decision:** Box–Cox = ", apply_boxcox, "; lambda = ", round(lambda, 6), "; shift = ", round(shift, 6), "; GSTAR d = ", d, "."), "",
  "### All variance-stationarity results", "", markdown_table(variance_results), "",
  "### All mean-stationarity results: ADF lags 0–12 and KPSS", "", markdown_table(mean_results), "",
  "## 4. Iterative GSTAR candidate identification", "",
  "Temporal orders p = 1 through p = 12 were fitted in a loop. Every candidate has separate parameter estimates, IIDN diagnostics, and residual cross-location correlations below. A fully IIDN candidate must have p-values of at least 0.05 for mean-zero, normality, variance stability, and both Ljung–Box tests at every location. If no full-IIDN candidate exists, the script selects the lowest-AIC candidate that passes the white-noise checks; otherwise it records the lowest-AIC finite-coefficient fallback.", "",
  "### Candidate summary and selection flags", "", markdown_table(candidates), "",
  "### All candidate parameter estimates", "", markdown_table(candidate_parameters), "",
  "### All candidate IIDN diagnostics", "", markdown_table(candidate_iidn), "",
  "### All candidate residual cross-location correlations", "", markdown_table(candidate_residual_correlations), "",
  "## 5. Selected GSTAR model", "", paste0("Selected temporal order: **p = ", selected_order, "**; differencing order: **d = ", d, "**."), "",
  "### All parameter estimates", "", markdown_table(coefficients), "",
  "## 6. IIDN residual diagnostics", "", "IIDN is assessed as: residual mean near zero (t-test), approximately constant variance (Fligner–Killeen), normality (Shapiro–Wilk), temporal independence (Ljung–Box at lags 10 and 20), and cross-location independence (correlation matrix below). A p-value below 0.05 is evidence against the relevant IIDN condition.", "", "### All IIDN diagnostic results", "", markdown_table(diagnostics), "",
  "### Residual cross-location correlation", "", markdown_table(residual_correlation_report), "",
  unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Residual diagnostics - ", name, "](plots_rstudio/04_residual_diagnostics_", tolower(name), ".png)"), ""))),
  "## 7. Untouched 20% test evaluation", "", "MSE, RMSE, and MAE use every test observation. `MAPE_nonzero` excludes zero observed rainfall; sMAPE is the zero-safe percentage metric.", "",
  "### All test metrics", "", markdown_table(metrics), "",
  "### All actual-versus-predicted test observations", "", markdown_table(test_predictions), "",
  unlist(lapply(locations, function(name) c(paste0("### ", name), "", paste0("![Hold-out forecast - ", name, "](plots_rstudio/05_test_forecast_", tolower(name), ".png)"), ""))),
  "## Reproducibility", "", "Run `Rscript Week2/gstar_rainfall_w2.R` in Docker. Source rainfall data are read only; derived files are written to `results/` and `plots_rstudio/`."
)
writeLines(report, report_path)
message("GSTAR workflow completed. Report: ", report_path)
