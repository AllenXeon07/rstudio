# GSTAR(a,b) utilities -------------------------------------------------------
# Source with: source("Week2/gstar_ab.R")
#
# Convention used here:
#   a = maximum temporal lag of the spatially weighted other-location effect
#   b = maximum temporal lag of the own-location effect
#
# For location i, the fitted model is
# Z_i,t = sum(k = 1..b) phi_i,k Z_i,t-k +
#         sum(l = 1..a) theta_i,l sum(j != i) w_i,j Z_j,t-l + e_i,t.
#
# The input must already be on the required model scale (for example, raw,
# Box-Cox transformed, or differenced data). This makes the fit and forecast
# steps explicit and avoids silently applying an inappropriate transformation.

validate_gstar_ab_input <- function(data, weight, a, b) {
  x <- as.matrix(data)
  storage.mode(x) <- "double"
  if (ncol(x) < 2L || anyNA(x) || any(!is.finite(x))) stop("data must be a complete numeric matrix with at least two locations.")
  if (is.null(colnames(x))) colnames(x) <- paste0("Location", seq_len(ncol(x)))
  w <- as.matrix(weight)
  storage.mode(w) <- "double"
  if (!identical(dim(w), c(ncol(x), ncol(x))) || anyNA(w) || any(!is.finite(w))) stop("weight must be a finite square matrix with one row and column per location.")
  if (any(diag(w) != 0)) stop("weight must have a zero diagonal so spatial effects exclude the same location.")
  if (length(a) != 1L || length(b) != 1L || a < 1L || b < 1L || a != as.integer(a) || b != as.integer(b)) stop("a and b must be positive integer lag orders.")
  max_lag <- max(a, b)
  if (nrow(x) <= max_lag + 1L) stop("Not enough observations for the requested GSTAR(a,b) orders.")
  list(x = x, w = w, a = as.integer(a), b = as.integer(b), max_lag = max_lag)
}

gstar_ab_design <- function(data, weight, a, b) {
  checked <- validate_gstar_ab_input(data, weight, a, b)
  x <- checked$x; w <- checked$w; locations <- colnames(x)
  n <- nrow(x); m <- ncol(x); max_lag <- checked$max_lag
  own_names <- unlist(lapply(seq_len(b), function(k) paste0("phi", k, "(", locations, ")")))
  spatial_names <- unlist(lapply(seq_len(a), function(k) paste0("theta", k, "(", locations, ")")))
  x_design <- matrix(0, nrow = (n - max_lag) * m, ncol = length(own_names) + length(spatial_names), dimnames = list(NULL, c(own_names, spatial_names)))
  response <- numeric(nrow(x_design)); response_time <- integer(nrow(x_design)); response_location <- character(nrow(x_design))
  row <- 0L
  for (time in (max_lag + 1L):n) for (i in seq_len(m)) {
    row <- row + 1L
    response[row] <- x[time, i]; response_time[row] <- time; response_location[row] <- locations[i]
    for (lag in seq_len(b)) x_design[row, (lag - 1L) * m + i] <- x[time - lag, i]
    for (lag in seq_len(a)) x_design[row, length(own_names) + (lag - 1L) * m + i] <- sum(w[i, ] * x[time - lag, ])
  }
  list(X = x_design, y = response, time = response_time, location = response_location, checked = checked)
}

#' Fit a GSTAR(a,b) model by ordinary least squares.
#'
#' @param data Stationary/transformed data matrix; columns are locations.
#' @param weight Row-oriented spatial weight matrix with a zero diagonal.
#' @param a Maximum lag for spatially weighted other-location terms.
#' @param b Maximum lag for own-location terms.
#' @return An object of class gstar_ab, usable with coef(), fitted(), residuals(),
#'   predict(), and summary().
gstar_ab_fit <- function(data, weight, a, b) {
  design <- gstar_ab_design(data, weight, a, b)
  lm_fit <- stats::lm.fit(design$X, design$y)
  rank <- lm_fit$rank; n_obs <- length(design$y); df_residual <- n_obs - rank
  rss <- sum(lm_fit$residuals^2)
  sigma2 <- rss / df_residual
  xtx_inverse <- tryCatch(chol2inv(chol(crossprod(design$X))), error = function(e) NULL)
  standard_error <- if (is.null(xtx_inverse)) rep(NA_real_, ncol(design$X)) else sqrt(diag(xtx_inverse) * sigma2)
  names(standard_error) <- colnames(design$X)
  coefficients <- lm_fit$coefficients; names(coefficients) <- colnames(design$X)
  t_value <- coefficients / standard_error
  p_value <- 2 * stats::pt(abs(t_value), df = df_residual, lower.tail = FALSE)
  fitted_matrix <- matrix(lm_fit$fitted.values, ncol = ncol(design$checked$x), byrow = TRUE, dimnames = list(design$checked$max_lag + seq_len(nrow(design$checked$x) - design$checked$max_lag), colnames(design$checked$x)))
  residual_matrix <- matrix(lm_fit$residuals, ncol = ncol(design$checked$x), byrow = TRUE, dimnames = dimnames(fitted_matrix))
  log_likelihood <- -0.5 * n_obs * (log(2 * pi) + 1 + log(rss / n_obs))
  out <- list(
    call = match.call(), a = design$checked$a, b = design$checked$b,
    weight = design$checked$w, locations = colnames(design$checked$x),
    data = design$checked$x, max_lag = design$checked$max_lag,
    coefficients = coefficients, std_error = standard_error, t_value = t_value,
    p_value = p_value, fitted_values = fitted_matrix, residuals = residual_matrix,
    residual_df = df_residual, sigma2 = sigma2, RSS = rss,
    AIC = -2 * log_likelihood + 2 * rank, rank = rank,
    design = design
  )
  class(out) <- "gstar_ab"
  out
}

coef.gstar_ab <- function(object, ...) object$coefficients
fitted.gstar_ab <- function(object, ...) object$fitted_values
residuals.gstar_ab <- function(object, ...) object$residuals

summary.gstar_ab <- function(object, ...) {
  list(
    model = paste0("GSTAR(", object$a, ", ", object$b, ")"),
    coefficients = data.frame(parameter = names(object$coefficients), estimate = as.numeric(object$coefficients), std_error = as.numeric(object$std_error), t_value = as.numeric(object$t_value), p_value = as.numeric(object$p_value), row.names = NULL),
    fit = data.frame(RSS = object$RSS, sigma2 = object$sigma2, AIC = object$AIC, residual_df = object$residual_df)
  )
}

print.gstar_ab <- function(x, ...) {
  cat("GSTAR(", x$a, ", ", x$b, ") fitted by OLS\n", sep = "")
  cat("Locations:", paste(x$locations, collapse = ", "), "\n")
  cat("AIC:", format(round(x$AIC, 3), nsmall = 3), "\n")
  invisible(x)
}

#' Produce recursive multi-step forecasts on the same model scale as data.
#' For differenced or Box-Cox data, inverse transformation is intentionally
#' left to the calling analysis after it supplies the needed initial values.
predict.gstar_ab <- function(object, n.ahead = 1L, ...) {
  n.ahead <- as.integer(n.ahead)
  if (length(n.ahead) != 1L || is.na(n.ahead) || n.ahead < 1L) stop("n.ahead must be a positive integer.")
  history <- rbind(object$data, matrix(NA_real_, nrow = n.ahead, ncol = ncol(object$data), dimnames = list(NULL, object$locations)))
  own_count <- object$b * length(object$locations)
  forecast <- matrix(NA_real_, nrow = n.ahead, ncol = length(object$locations), dimnames = list(seq_len(n.ahead), object$locations))
  for (step in seq_len(n.ahead)) {
    time <- nrow(object$data) + step
    for (i in seq_along(object$locations)) {
      value <- 0
      for (lag in seq_len(object$b)) value <- value + object$coefficients[(lag - 1L) * length(object$locations) + i] * history[time - lag, i]
      for (lag in seq_len(object$a)) value <- value + object$coefficients[own_count + (lag - 1L) * length(object$locations) + i] * sum(object$weight[i, ] * history[time - lag, ])
      forecast[step, i] <- value
    }
    history[time, ] <- forecast[step, ]
  }
  forecast
}

#' Expand fitted parameters into the paper-style city equations.
gstar_ab_equation_terms <- function(object) {
  stopifnot(inherits(object, "gstar_ab"))
  do.call(rbind, lapply(seq_along(object$locations), function(i) {
    own <- do.call(rbind, lapply(seq_len(object$b), function(lag) data.frame(location = object$locations[i], lag = lag, source_location = object$locations[i], effect = "own temporal", parameter = paste0("phi", lag, "(", object$locations[i], ")"), spatial_weight = 1, coefficient = object$coefficients[(lag - 1L) * length(object$locations) + i])))
    spatial <- do.call(rbind, lapply(seq_len(object$a), function(lag) do.call(rbind, lapply(which(seq_along(object$locations) != i), function(j) data.frame(location = object$locations[i], lag = lag, source_location = object$locations[j], effect = "spatial weighted", parameter = paste0("theta", lag, "(", object$locations[i], ")"), spatial_weight = object$weight[i, j], coefficient = object$coefficients[object$b * length(object$locations) + (lag - 1L) * length(object$locations) + i] * object$weight[i, j])))))
    rbind(own, spatial)
  }))
}
